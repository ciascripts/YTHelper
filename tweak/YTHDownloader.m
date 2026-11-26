#import "YTHDownloader.h"
#import <AVFoundation/AVFoundation.h>
#include <ctype.h>
#include <limits.h>
#include <string.h>

@implementation YTHStream
@end

// H.264 MP4 video-only itags, best first, with their heights.
// 299/298 are the 60 fps variants of 1080p/720p.
static NSArray<NSArray<NSNumber *> *> *YTHVideoItags(void) {
    return @[@[@299, @1080], @[@137, @1080], @[@298, @720], @[@136, @720],
             @[@135, @480], @[@134, @360], @[@133, @240]];
}
static NSArray<NSNumber *> *YTHAudioItags(void) { return @[@140, @139]; } // AAC 128k, 48k
static const int YTHProgressiveItag = 18;                                  // 360p H.264 + AAC
static const long long YTHChunkSize = 10 * 1024 * 1024;                   // googlevideo throttles big ranges

static BOOL gBusy;

@interface YTHDownloadJob : NSObject
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) UIAlertController *progressAlert;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSURL *workDir;
@property (atomic, assign) BOOL cancelled;
- (void)setStatus:(NSString *)status;
@end

static NSError *YTHError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YTHelper" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL YTHReadNumber(const char **p, long long *out) {
    const char *s = *p;
    if (!isdigit((unsigned char)*s)) return NO;
    long long v = 0;
    while (isdigit((unsigned char)*s)) {
        if (v > (LLONG_MAX - 9) / 10) return NO; // overflow
        v = v * 10 + (*s++ - '0');
    }
    *out = v;
    *p = s;
    return YES;
}

// Strictly parses "bytes START-END/TOTAL" or "bytes START-END/*" (total = -1 for "*").
// Rejects anything else, including a missing "/TOTAL", END < START or END >= TOTAL.
static BOOL YTHParseContentRange(NSString *header, long long *start, long long *end, long long *total) {
    const char *h = header.UTF8String;
    if (!h || strncmp(h, "bytes ", 6) != 0) return NO;
    const char *p = h + 6;
    long long s, e, t = -1;
    if (!YTHReadNumber(&p, &s) || *p++ != '-' || !YTHReadNumber(&p, &e) || *p++ != '/') return NO;
    if (*p == '*') p++;
    else if (!YTHReadNumber(&p, &t)) return NO;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '\0' || e < s || (t >= 0 && e >= t)) return NO;
    *start = s;
    *end = e;
    *total = t;
    return YES;
}

// Strictly parses the 416 form "bytes */TOTAL".
static BOOL YTHParseUnsatisfiedRange(NSString *header, long long *total) {
    const char *h = header.UTF8String;
    if (!h || strncmp(h, "bytes */", 8) != 0) return NO;
    const char *p = h + 8;
    long long t;
    if (!YTHReadNumber(&p, &t)) return NO;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '\0') return NO;
    *total = t;
    return YES;
}

// Downloads one URL to one file in 10 MB ranges. Each request's completion handler
// keeps this object alive until the next request starts, so no block refers to itself.
@interface YTHRangeFetch : NSObject
@property (nonatomic, weak) YTHDownloadJob *job;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) void (^done)(NSError *);
@property (nonatomic, assign) long long offset;
@property (nonatomic, assign) long long total;
- (void)next;
@end

@implementation YTHRangeFetch

- (void)finishWithError:(NSError *)error {
    [self.handle closeAndReturnError:nil];
    void (^done)(NSError *) = self.done;
    self.done = nil; // call at most once
    if (done) done(error);
}

- (void)next {
    YTHDownloadJob *job = self.job;
    if (!job || job.cancelled) { [self finishWithError:YTHError(-999, @"Cancelled")]; return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.url];
    [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", self.offset, self.offset + YTHChunkSize - 1] forHTTPHeaderField:@"Range"];
    if (self.userAgent.length) [req setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    [[job.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [self handleData:data response:(NSHTTPURLResponse *)response error:error];
    }] resume];
}

- (void)handleData:(NSData *)data response:(NSHTTPURLResponse *)http error:(NSError *)error {
    if (!error && http.statusCode == 416) {
        // "Range not satisfiable": only a success if it confirms the file ends exactly here.
        long long confirmed = -1;
        if (YTHParseUnsatisfiedRange([http valueForHTTPHeaderField:@"Content-Range"], &confirmed) &&
            confirmed == self.offset && (self.total < 0 || self.total == confirmed)) {
            self.total = confirmed;
            [self finishWithError:nil];
        } else {
            [self finishWithError:YTHError(5, @"YouTube sent an unexpected part of the file. Try again.")];
        }
        return;
    }
    if (error || (http.statusCode != 200 && http.statusCode != 206) || data.length == 0) {
        // Pass network errors through unchanged so a cancel keeps code -999.
        [self finishWithError:error ?: YTHError(http.statusCode,
            [NSString stringWithFormat:@"YouTube refused the download (HTTP %ld).", (long)http.statusCode])];
        return;
    }
    NSError *writeError = nil;
    if (http.statusCode == 200) {
        // The server ignored Range and sent the whole file. Whatever we wrote before is
        // replaced so the output can't contain earlier chunks plus a full copy.
        if (![self.handle truncateAtOffset:0 error:&writeError] || ![self.handle writeData:data error:&writeError]) {
            [self finishWithError:writeError ?: YTHError(4, @"Couldn't write the download to storage.")];
            return;
        }
        self.offset = self.total = data.length;
        [self finishWithError:nil];
        return;
    }
    // A 206 must describe exactly the bytes we got, starting where we left off, and must not
    // change the file size mid-download. Otherwise a short body could look like a finished file.
    long long start = -1, end = -1, rangeTotal = -1;
    if (!YTHParseContentRange([http valueForHTTPHeaderField:@"Content-Range"], &start, &end, &rangeTotal) ||
        start != self.offset ||
        (long long)data.length != end - start + 1 ||
        (self.total >= 0 && rangeTotal >= 0 && rangeTotal != self.total) ||
        (self.total >= 0 && end >= self.total)) {
        [self finishWithError:YTHError(5, @"YouTube sent an unexpected part of the file. Try again.")];
        return;
    }
    if (![self.handle writeData:data error:&writeError]) {
        [self finishWithError:writeError ?: YTHError(4, @"Couldn't write the download to storage.")];
        return;
    }
    self.offset += data.length;
    if (rangeTotal >= 0) self.total = rangeTotal;
    if (self.total > 0)
        [self.job setStatus:[NSString stringWithFormat:@"%@ %d%%", self.label, (int)(self.offset * 100 / self.total)]];
    // Finished only when a known total is reached. With an unknown ("*") total, or when the
    // server caps responses below our chunk size, keep asking from the next offset; the end
    // is then confirmed by a total in a later response or by a 416 "bytes */N" at N.
    if (self.total >= 0 && self.offset >= self.total) [self finishWithError:nil];
    else [self next];
}

@end

@implementation YTHDownloadJob

- (void)setStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{ self.progressAlert.message = status; });
}

// Downloads a stream to file in 10 MB ranges. Calls done(error) on a background queue.
- (void)fetch:(YTHStream *)stream to:(NSURL *)file label:(NSString *)label done:(void (^)(NSError *))done {
    NSError *fileError = nil;
    if (![[NSFileManager defaultManager] createFileAtPath:file.path contents:nil attributes:nil]) {
        done(YTHError(3, @"Couldn't create a file for the download."));
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:&fileError];
    if (!handle) {
        done(fileError ?: YTHError(3, @"Couldn't open the download file."));
        return;
    }
    YTHRangeFetch *fetch = [YTHRangeFetch new];
    fetch.job = self;
    fetch.url = stream.URL;
    fetch.userAgent = stream.userAgent;
    fetch.handle = handle;
    fetch.label = label;
    fetch.done = done;
    fetch.total = -1;
    [fetch next];
}

@end

@implementation YTHDownloader

+ (BOOL)isBusy { return gBusy; }

static YTHStream *YTHFind(NSArray<YTHStream *> *streams, int itag) {
    for (YTHStream *s in streams) if (s.itag == itag && s.URL) return s;
    return nil;
}

static NSString *YTHSafeFileName(NSString *title) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    NSString *name = [[title componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@" "];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length > 80) name = [name substringToIndex:80];
    return name.length ? name : @"video";
}

// ---------- Fallback: ask YouTube's player API for direct links ----------
// The YouTube app on newer versions streams over SABR, which carries no plain stream URLs.
// The Android VR client still gets plain URLs without extra tokens, so ask as that client.
// These values follow yt-dlp's client list and may need bumping when YouTube changes them.
static NSString *const YTHVRClientVersion = @"1.62.27";
static NSString *YTHVRUserAgent(void) {
    return [NSString stringWithFormat:@"com.google.android.apps.youtube.vr.oculus/%@ (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip", YTHVRClientVersion];
}

+ (void)fetchStreamsForVideoID:(NSString *)videoID completion:(void (^)(NSArray<YTHStream *> *streams, NSString *title, NSError *error))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:YTHVRUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"28" forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [req setValue:YTHVRClientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    NSDictionary *body = @{
        @"context": @{ @"client": @{
            @"clientName": @"ANDROID_VR", @"clientVersion": YTHVRClientVersion,
            @"deviceMake": @"Oculus", @"deviceModel": @"Quest 3",
            @"androidSdkVersion": @32, @"osName": @"Android", @"osVersion": @"12L",
            @"hl": @"en", @"gl": @"US",
        } },
        @"videoId": videoID,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES,
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    void (^finish)(NSArray *, NSString *, NSError *) = ^(NSArray *streams, NSString *title, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(streams, title, error); });
    };
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { finish(nil, nil, error); return; }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            finish(nil, nil, YTHError(6, [NSString stringWithFormat:@"YouTube's player API sent an unexpected reply (HTTP %ld).", (long)((NSHTTPURLResponse *)response).statusCode]));
            return;
        }
        NSDictionary *playability = [json[@"playabilityStatus"] isKindOfClass:NSDictionary.class] ? json[@"playabilityStatus"] : nil;
        NSString *status = playability[@"status"];
        if (![status isEqual:@"OK"]) {
            NSString *reason = [playability[@"reason"] isKindOfClass:NSString.class] ? playability[@"reason"] : (status ?: @"no reason given");
            finish(nil, nil, YTHError(7, [NSString stringWithFormat:@"YouTube said: %@", reason]));
            return;
        }
        NSMutableArray<YTHStream *> *streams = [NSMutableArray array];
        NSDictionary *sd = [json[@"streamingData"] isKindOfClass:NSDictionary.class] ? json[@"streamingData"] : nil;
        for (NSString *key in @[@"adaptiveFormats", @"formats"]) {
            NSArray *formats = [sd[key] isKindOfClass:NSArray.class] ? sd[key] : nil;
            for (NSDictionary *f in formats) {
                if (![f isKindOfClass:NSDictionary.class]) continue;
                NSNumber *itag = [f[@"itag"] isKindOfClass:NSNumber.class] ? f[@"itag"] : nil;
                NSString *url = [f[@"url"] isKindOfClass:NSString.class] ? f[@"url"] : nil;
                if (!itag || !url.length) continue; // ciphered formats have no plain url
                YTHStream *s = [YTHStream new];
                s.itag = itag.intValue;
                s.URL = [NSURL URLWithString:url];
                s.userAgent = YTHVRUserAgent();
                if (s.URL) [streams addObject:s];
            }
        }
        NSDictionary *details = [json[@"videoDetails"] isKindOfClass:NSDictionary.class] ? json[@"videoDetails"] : nil;
        NSString *title = [details[@"title"] isKindOfClass:NSString.class] ? details[@"title"] : nil;
        finish(streams, title, nil);
    }] resume];
}

+ (void)downloadTitle:(NSString *)title videoID:(NSString *)videoID streams:(NSArray<YTHStream *> *)streams maxHeight:(NSInteger)maxHeight presenter:(UIViewController *)presenter {
    if (gBusy) return;

    YTHStream *audio = nil;
    for (NSNumber *itag in YTHAudioItags()) if ((audio = YTHFind(streams, itag.intValue))) break;
    YTHStream *video = nil;
    if (maxHeight > 0) {
        for (NSArray<NSNumber *> *pair in YTHVideoItags()) {
            if (pair[1].integerValue > maxHeight) continue;
            if ((video = YTHFind(streams, pair[0].intValue))) break;
        }
    }
    YTHStream *progressive = YTHFind(streams, YTHProgressiveItag);

    BOOL audioOnly = maxHeight == 0;
    if ((audioOnly && !audio) || (!audioOnly && !(video && audio) && !progressive)) {
        if (videoID.length) {
            // The app has no usable links (SABR). Ask YouTube's player API, then try once more.
            gBusy = YES;
            UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Downloading" message:@"Getting download links…" preferredStyle:UIAlertControllerStyleAlert];
            [presenter presentViewController:wait animated:YES completion:nil];
            [self fetchStreamsForVideoID:videoID completion:^(NSArray<YTHStream *> *apiStreams, NSString *apiTitle, NSError *error) {
                gBusy = NO;
                [wait dismissViewControllerAnimated:YES completion:^{
                    if (error) {
                        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Can't download this video" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [presenter presentViewController:a animated:YES completion:nil];
                        return;
                    }
                    [self downloadTitle:(title.length ? title : apiTitle) videoID:nil streams:apiStreams maxHeight:maxHeight presenter:presenter];
                }];
            }];
            return;
        }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Can't download this video"
            message:@"Neither the app nor YouTube's player API gave a downloadable stream for this video. This can happen for live, premium or age-restricted videos, or when YouTube changes how it serves videos."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:a animated:YES completion:nil];
        return;
    }
    gBusy = YES;

    YTHDownloadJob *job = [YTHDownloadJob new];
    job.title = YTHSafeFileName(title);
    job.presenter = presenter;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60;
    job.session = [NSURLSession sessionWithConfiguration:config];
    job.workDir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID UUID].UUIDString isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:job.workDir withIntermediateDirectories:YES attributes:nil error:nil];

    job.progressAlert = [UIAlertController alertControllerWithTitle:@"Downloading" message:@"Starting…" preferredStyle:UIAlertControllerStyleAlert];
    __weak YTHDownloadJob *weakJob = job; // the alert is owned by the job
    [job.progressAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        weakJob.cancelled = YES;
        [weakJob.session invalidateAndCancel];
    }]];
    [presenter presentViewController:job.progressAlert animated:YES completion:nil];

    void (^finish)(NSURL *, NSError *) = ^(NSURL *output, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gBusy = NO;
            [job.session finishTasksAndInvalidate];
            void (^showResult)(void) = ^{
                UIViewController *p = job.presenter;
                if (error) {
                    if (error.code != -999) {
                        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Download failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [p presentViewController:a animated:YES completion:nil];
                    }
                    [[NSFileManager defaultManager] removeItemAtURL:job.workDir error:nil];
                    return;
                }
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[output] applicationActivities:nil];
                share.popoverPresentationController.sourceView = p.view;
                share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(p.view.bounds), CGRectGetMidY(p.view.bounds), 1, 1);
                share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *err) {
                    [[NSFileManager defaultManager] removeItemAtURL:job.workDir error:nil];
                };
                [p presentViewController:share animated:YES completion:nil];
            };
            // After Cancel the alert has already dismissed itself.
            if (job.progressAlert.presentingViewController)
                [job.progressAlert dismissViewControllerAnimated:YES completion:showResult];
            else
                showResult();
        });
    };

    // Raw streams and finished files live in different folders so a video titled "video"
    // can't overwrite the raw video.mp4. Raw files keep real extensions for AVFoundation.
    NSURL *rawDir = [job.workDir URLByAppendingPathComponent:@"raw" isDirectory:YES];
    NSURL *outDir = [job.workDir URLByAppendingPathComponent:@"out" isDirectory:YES];
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:rawDir withIntermediateDirectories:YES attributes:nil error:&dirError] ||
        ![[NSFileManager defaultManager] createDirectoryAtURL:outDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        finish(nil, dirError);
        return;
    }
    NSURL *audioFile = [rawDir URLByAppendingPathComponent:@"audio.m4a"];
    NSURL *videoFile = [rawDir URLByAppendingPathComponent:@"video.mp4"];

    if (audioOnly) {
        [job fetch:audio to:audioFile label:@"Audio" done:^(NSError *error) {
            if (error) { finish(nil, error); return; }
            NSURL *out = [outDir URLByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"m4a"]];
            [job setStatus:@"Saving…"];
            [self exportAsset:[AVURLAsset URLAssetWithURL:audioFile options:nil] to:out type:AVFileTypeAppleM4A done:^(NSError *e) { finish(out, e); }];
        }];
        return;
    }

    if (!(video && audio)) {
        // Only the 360p progressive file is available; it already has sound.
        [job fetch:progressive to:videoFile label:@"Video" done:^(NSError *error) {
            if (error) { finish(nil, error); return; }
            NSURL *out = [outDir URLByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"mp4"]];
            NSError *moveError = nil;
            if ([[NSFileManager defaultManager] moveItemAtURL:videoFile toURL:out error:&moveError]) finish(out, nil);
            else finish(nil, moveError);
        }];
        return;
    }

    [job fetch:video to:videoFile label:@"Video" done:^(NSError *error) {
        if (error) { finish(nil, error); return; }
        [job fetch:audio to:audioFile label:@"Audio" done:^(NSError *error2) {
            if (error2) { finish(nil, error2); return; }
            [job setStatus:@"Merging…"];
            NSURL *out = [outDir URLByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"mp4"]];
            [self mergeVideo:videoFile audio:audioFile to:out done:^(NSError *e) { finish(out, e); }];
        }];
    }];
}

+ (void)mergeVideo:(NSURL *)videoFile audio:(NSURL *)audioFile to:(NSURL *)out done:(void (^)(NSError *))done {
    AVURLAsset *v = [AVURLAsset URLAssetWithURL:videoFile options:nil];
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:audioFile options:nil];
    AVAssetTrack *vt = [v tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *at = [a tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!vt || !at) {
        done(YTHError(1, @"The downloaded streams couldn't be read."));
        return;
    }
    AVMutableComposition *comp = [AVMutableComposition composition];
    CMTimeRange range = CMTimeRangeMake(kCMTimeZero, v.duration);
    NSError *err = nil;
    AVMutableCompositionTrack *cv = [comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [cv insertTimeRange:range ofTrack:vt atTime:kCMTimeZero error:&err];
    cv.preferredTransform = vt.preferredTransform;
    AVMutableCompositionTrack *ca = [comp addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTimeRange audioRange = CMTimeRangeMake(kCMTimeZero, CMTimeMinimum(v.duration, a.duration));
    if (!err) [ca insertTimeRange:audioRange ofTrack:at atTime:kCMTimeZero error:&err];
    if (err) { done(err); return; }
    [self exportAsset:comp to:out type:AVFileTypeMPEG4 done:done];
}

+ (void)exportAsset:(AVAsset *)asset to:(NSURL *)out type:(AVFileType)type done:(void (^)(NSError *))done {
    AVAssetExportSession *export = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (!export || ![export.supportedFileTypes containsObject:type]) {
        done(YTHError(2, @"This video's format can't be saved as a file on this device."));
        return;
    }
    export.outputURL = out;
    export.outputFileType = type;
    export.shouldOptimizeForNetworkUse = YES;
    [export exportAsynchronouslyWithCompletionHandler:^{
        if (export.status == AVAssetExportSessionStatusCompleted) done(nil);
        else done(export.error ?: YTHError(2, @"Couldn't save the file."));
    }];
}

@end
