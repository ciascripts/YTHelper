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

static __weak YTPlayerViewController *gPlayerVC; // most recent player, used by the bottom-bar button

static UIImage *YTHDownloadIcon(void) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:OVERLAY_BUTTON_SIZE weight:UIImageSymbolWeightMedium];
    return [[UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
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
        s.URL = [f URL];
        if (s.URL) [streams addObject:s];
    };
    void (^addFormatStream)(id) = ^(id fs) {
        NSString *url = nil;
        @try { url = [fs valueForKey:@"URL"]; } @catch (NSException *e) {}
        int itag = YTHIntValue(fs, @"itag");
        if (url.length && itag) {
            YTHStream *s = [YTHStream new];
            s.itag = itag;
            s.URL = [NSURL URLWithString:url];
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
        if (!title.length && [player respondsToSelector:@selector(contentVideoID)]) title = [player contentVideoID];
        *titleOut = title;
    }
    return streams;
}

static void YTHStartDownload(YTPlayerViewController *player) {
    if (!player) return;
    if ([YTHDownloader isBusy]) return;
    if ([player respondsToSelector:@selector(isPlayingAd)] && player.isPlayingAd) return;
    NSString *title = nil;
    NSArray *streams = YTHCollectStreams(player, &title);
    UIViewController *presenter = YTHTopViewController() ?: player;
    [YTHDownloader downloadTitle:title ?: @"video" streams:streams maxHeight:YTHDownloadQuality() presenter:presenter];
}

%group Top
%hook YTMainAppControlsOverlayView

- (void)setPlayerViewController:(YTPlayerViewController *)vc {
    %orig;
    if (vc) gPlayerVC = vc;
}

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:TweakKey] ? YTHDownloadIcon() : %orig;
}

%new(v@:@)
- (void)didPressYTHelperDownload:(id)arg {
    YTHStartDownload(self.playerViewController ?: gPlayerVC);
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
    YTHStartDownload(gPlayerVC);
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
}
