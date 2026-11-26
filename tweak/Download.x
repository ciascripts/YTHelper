// Download button on the video player, added through PoomSmart's YTVideoOverlay (MIT).
#import <YTVideoOverlay/Header.h>
#import <YTVideoOverlay/Init.x>
#import <YouTubeHeader/MLFormat.h>
#import <YouTubeHeader/MLStreamingData.h>
#import <YouTubeHeader/MLVideo.h>
#import <YouTubeHeader/YTIFormatStream.h>
#import <YouTubeHeader/YTIStreamingData.h>
#import <YouTubeHeader/YTIVideoDetails.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideo.h>
#import <YouTubeHeader/YTSingleVideoController.h>
#import "Prefs.h"
#import "YTHDownloader.h"

#define TweakKey @"YTHelper"

@interface YTMainAppControlsOverlayView (YTHelper)
- (void)didPressYTHelperDownload:(id)arg;
@end

@interface YTInlinePlayerBarContainerView (YTHelper)
- (void)didPressYTHelperDownload:(id)arg;
@end

static __weak YTPlayerViewController *gPlayerVC; // most recent player, used as a fallback

static UIImage *YTHDownloadIcon(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:OVERLAY_BUTTON_SIZE weight:UIImageSymbolWeightMedium];
    return [[UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Accepts an NSURL or a URL string; anything else (or an empty string) gives nil.
static NSURL *YTHAsURL(id value) {
    if ([value isKindOfClass:NSURL.class]) return value;
    if ([value isKindOfClass:NSString.class] && [value length]) return [NSURL URLWithString:value];
    return nil;
}

static int YTHIntValue(id obj, NSString *key) {
    @try { return [[obj valueForKey:key] intValue]; } @catch (NSException *e) { return 0; }
}

// Collect every stream the player knows about. Each source is optional because YouTube
// moves these around between versions.
static NSArray<YTHStream *> *YTHCollectStreams(YTPlayerViewController *player, NSString **titleOut) {
    NSMutableArray<YTHStream *> *streams = [NSMutableArray array];
    void (^addFormat)(MLFormat *) = ^(MLFormat *f) {
        if (![f respondsToSelector:@selector(itag)] || ![f respondsToSelector:@selector(URL)]) return;
        YTHStream *s = [YTHStream new];
        s.itag = [f itag];
        s.URL = YTHAsURL([f URL]); // some versions return a string here
        if (s.URL) [streams addObject:s];
    };
    void (^addFormatStream)(id) = ^(id fs) {
        id url = nil;
        @try { url = [fs valueForKey:@"URL"]; } @catch (NSException *e) {}
        int itag = YTHIntValue(fs, @"itag");
        if (YTHAsURL(url) && itag) {
            YTHStream *s = [YTHStream new];
            s.itag = itag;
            s.URL = YTHAsURL(url);
            [streams addObject:s];
        }
    };

    YTSingleVideoController *active = [player respondsToSelector:@selector(activeVideo)] ? [player activeVideo] : nil;
    if ([active respondsToSelector:@selector(selectableVideoFormats)])
        for (MLFormat *f in [active selectableVideoFormats]) addFormat(f);

    YTSingleVideo *single = [active respondsToSelector:@selector(singleVideo)] ? [active singleVideo] : nil;
    MLVideo *video = [single respondsToSelector:@selector(video)] ? [single video] : nil;
    MLStreamingData *streaming = [video respondsToSelector:@selector(streamingData)] ? [video streamingData] : nil;
    if ([streaming respondsToSelector:@selector(adaptiveStreams)])
        for (MLFormat *f in [streaming adaptiveStreams]) addFormat(f);
    YTIStreamingData *raw = [streaming respondsToSelector:@selector(streamingData)] ? streaming.streamingData : nil;
    if ([raw respondsToSelector:@selector(adaptiveFormatsArray)])
        for (id fs in [raw adaptiveFormatsArray]) addFormatStream(fs);
    if ([raw respondsToSelector:@selector(formatsArray)])
        for (id fs in [raw formatsArray]) addFormatStream(fs);

    if (titleOut) {
        NSString *title = nil;
        @try { title = [[video videoDetails] valueForKey:@"title"]; } @catch (NSException *e) {}
        *titleOut = title;
    }
    return streams;
}

static void YTHShowError(NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Download error" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [YTHTopViewController() presentViewController:a animated:YES completion:nil];
}

// Anything that can hand us the current video counts as "the player"; this avoids depending on
// class or property names that YouTube changes between versions.
static BOOL YTHLooksLikePlayer(id obj) {
    return obj && [obj respondsToSelector:@selector(activeVideo)];
}

// Class names from the button up to the window, shown when no player is found so the
// next fix can target the right object.
static NSString *YTHResponderChain(id start) {
    NSMutableArray *names = [NSMutableArray array];
    if ([start isKindOfClass:UIResponder.class])
        for (UIResponder *r = start; r && names.count < 25; r = r.nextResponder)
            [names addObject:NSStringFromClass(r.class)];
    return [names componentsJoinedByString:@" > "];
}

static void YTHStartDownload(YTPlayerViewController *player, id sender) {
    // Any Objective-C exception here (e.g. a method YouTube renamed) becomes an error message
    // with the reason, instead of crashing the app.
    @try {
        if (!player) {
            YTHShowError([NSString stringWithFormat:@"Couldn't find the video player. Start playing the video and try again.\n\nDetails for the developer: %@", YTHResponderChain(sender)]);
            return;
        }
        if ([YTHDownloader isBusy]) return;
        if ([player respondsToSelector:@selector(isPlayingAd)] && player.isPlayingAd) return;
        NSString *title = nil;
        NSArray *streams = YTHCollectStreams(player, &title);
        NSString *videoID = nil;
        if ([player respondsToSelector:@selector(contentVideoID)]) videoID = [player contentVideoID];
        if (!videoID.length && [player respondsToSelector:@selector(currentVideoID)]) videoID = [player currentVideoID];
        UIViewController *presenter = YTHTopViewController() ?: (UIViewController *)player;
        [YTHDownloader downloadTitle:title videoID:videoID streams:streams maxHeight:YTHDownloadQuality() presenter:presenter];
    } @catch (NSException *e) {
        YTHShowError([NSString stringWithFormat:@"%@: %@\n\nPlease send this message to the YTHelper developer.", e.name, e.reason]);
    }
}

// Finds the player that owns this button:
// 1. the overlay's playerViewController property, if this YouTube version still has it;
// 2. walking up the responder chain (button -> views -> view controllers and their parents);
// 3. the last player that appeared on screen.
static YTPlayerViewController *YTHPlayerFromOverlay(id overlay) {
    id player = nil;
    if ([overlay respondsToSelector:@selector(playerViewController)]) {
        @try { player = [overlay playerViewController]; } @catch (NSException *e) {}
    }
    if (!YTHLooksLikePlayer(player)) player = nil;
    if (!player && [overlay isKindOfClass:UIResponder.class]) {
        for (UIResponder *r = overlay; r && !player; r = r.nextResponder) {
            if (YTHLooksLikePlayer(r)) { player = r; break; }
            if ([r isKindOfClass:UIViewController.class])
                for (UIViewController *vc = ((UIViewController *)r).parentViewController; vc; vc = vc.parentViewController)
                    if (YTHLooksLikePlayer(vc)) { player = vc; break; }
        }
    }
    if (!player && YTHLooksLikePlayer(gPlayerVC)) player = gPlayerVC;
    return player;
}

%group Top
%hook YTMainAppControlsOverlayView

- (void)setPlayerViewController:(YTPlayerViewController *)vc {
    %orig;
    if (YTHLooksLikePlayer(vc)) gPlayerVC = vc;
}

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:TweakKey] ? YTHDownloadIcon() : %orig;
}

%new(v@:@)
- (void)didPressYTHelperDownload:(id)arg {
    YTHStartDownload(YTHPlayerFromOverlay(self), self);
}

%end
%end

%group Bottom
%hook YTInlinePlayerBarContainerView

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:TweakKey] ? YTHDownloadIcon() : %orig;
}

%new(v@:@)
- (void)didPressYTHelperDownload:(id)arg {
    YTHStartDownload(YTHPlayerFromOverlay(self), self);
}

%end
%end

// Remember the player whenever one appears, as a last-resort fallback.
%group TrackPlayer
%hook YTPlayerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (YTHLooksLikePlayer(self)) gPlayerVC = self;
}
%end
%end

%ctor {
    // Show the button by default; it can be turned off or moved in YTVideoOverlay settings.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ @"YTVideoOverlay-YTHelper-Enabled": @YES }];
    initYTVideoOverlay(TweakKey, @{
        AccessibilityLabelKey: @"Download",
        SelectorKey: @"didPressYTHelperDownload:",
    });
    %init(Top);
    %init(Bottom);
    if (%c(YTPlayerViewController)) %init(TrackPlayer);
}
