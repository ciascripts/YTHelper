#import "YTHDownloader.h"
#import <AVFoundation/AVFoundation.h>

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
@end

@implementation YTHDownloadJob

- (void)setStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{ self.progressAlert.message = status; });
}

// Downloads url to file in 10 MB ranges. Calls done(error) on a background queue.
- (void)fetch:(NSURL *)url to:(NSURL *)file label:(NSString *)label done:(void (^)(NSError *))done {
    [[NSFileManager defaultManager] createFileAtPath:file.path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:file error:nil];
    __block long long offset = 0, total = -1;
    __block void (^next)(void);
    __weak typeof(self) weakSelf = self;
    void (^finishFetch)(NSError *) = ^(NSError *error) {
        [handle closeFile];
        next = nil; // break the self-referencing block
        done(error);
    };
    next = ^{
        typeof(self) job = weakSelf;
        if (!job || job.cancelled) { finishFetch([NSError errorWithDomain:@"YTHelper" code:-999 userInfo:@{NSLocalizedDescriptionKey: @"Cancelled"}]); return; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + YTHChunkSize - 1] forHTTPHeaderField:@"Range"];
        [[job.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (error || (http.statusCode != 200 && http.statusCode != 206) || data.length == 0) {
                // Pass network errors through unchanged so a cancel keeps code -999.
                finishFetch(error ?: [NSError errorWithDomain:@"YTHelper" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"YouTube refused the download (HTTP %ld).", (long)http.statusCode]}]);
                return;
            }
            [handle writeData:data];
            offset += data.length;
            NSString *range = http.allHeaderFields[@"Content-Range"]; // "bytes 0-10485759/123456789"
            if (total < 0 && range) total = [[range componentsSeparatedByString:@"/"].lastObject longLongValue];
            if (http.statusCode == 200) total = offset; // server ignored Range and sent everything
            if (total > 0)
                [job setStatus:[NSString stringWithFormat:@"%@ %d%%", label, (int)(offset * 100 / total)]];
            if (total > 0 && offset >= total) finishFetch(nil);
            else if ((long long)data.length < YTHChunkSize && total <= 0) finishFetch(nil);
            else next();
        }] resume];
    };
    next();
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

+ (void)downloadTitle:(NSString *)title streams:(NSArray<YTHStream *> *)streams maxHeight:(NSInteger)maxHeight presenter:(UIViewController *)presenter {
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
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Can't download this video"
            message:@"YouTube didn't give the app a downloadable stream for it. This happens when YouTube streams in a format the downloader can't read yet (SABR), or for live, premium or age-restricted videos."
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
    [job.progressAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        job.cancelled = YES;
        [job.session invalidateAndCancel];
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

    NSURL *audioFile = [job.workDir URLByAppendingPathComponent:@"audio.mp4"];
    NSURL *videoFile = [job.workDir URLByAppendingPathComponent:@"video.mp4"];

    if (audioOnly) {
        [job fetch:audio.URL to:audioFile label:@"Audio" done:^(NSError *error) {
            if (error) { finish(nil, error); return; }
            NSURL *out = [job.workDir URLByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"m4a"]];
            [job setStatus:@"Saving…"];
            [self exportAsset:[AVURLAsset URLAssetWithURL:audioFile options:nil] to:out type:AVFileTypeAppleM4A done:^(NSError *e) { finish(out, e); }];
        }];
        return;
    }

    if (!(video && audio)) {
        // Only the 360p progressive file is available; it already has sound.
        [job fetch:progressive.URL to:videoFile label:@"Video" done:^(NSError *error) {
            if (error) { finish(nil, error); return; }
            NSURL *out = [job.workDir URLByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"mp4"]];
            [[NSFileManager defaultManager] moveItemAtURL:videoFile toURL:out error:nil];
            finish(out, nil);
        }];
        return;
    }

    [job fetch:video.URL to:videoFile label:@"Video" done:^(NSError *error) {
        if (error) { finish(nil, error); return; }
        [job fetch:audio.URL to:audioFile label:@"Audio" done:^(NSError *error2) {
            if (error2) { finish(nil, error2); return; }
            [job setStatus:@"Merging…"];
            NSURL *out = [job.workDir URLByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"mp4"]];
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
        done([NSError errorWithDomain:@"YTHelper" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The downloaded streams couldn't be read."}]);
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
    export.outputURL = out;
    export.outputFileType = type;
    export.shouldOptimizeForNetworkUse = YES;
    [export exportAsynchronouslyWithCompletionHandler:^{
        if (export.status == AVAssetExportSessionStatusCompleted) done(nil);
        else done(export.error ?: [NSError errorWithDomain:@"YTHelper" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Couldn't save the file."}]);
    }];
}

@end
