// Shared settings for YTHelper. All values live in the app's standard NSUserDefaults.
#import <UIKit/UIKit.h>

#define YTHBlockAdsKey        @"YTHelper-BlockAds"
#define YTHInAppNameKey       @"YTHelper-InAppName"
#define YTHUseCustomLogoKey   @"YTHelper-UseCustomLogo"
#define YTHDownloadQualityKey @"YTHelper-DownloadQuality"

// Download quality values (max height; 0 = audio only)
#define YTHDownloadAudioOnly 0

static inline NSUserDefaults *YTHDefaults(void) { return [NSUserDefaults standardUserDefaults]; }

// Ads are blocked unless the user turned it off. Read at launch, so changes need a restart.
static inline BOOL YTHBlockAds(void) {
    id v = [YTHDefaults() objectForKey:YTHBlockAdsKey];
    return v ? [v boolValue] : YES;
}

static inline NSString *YTHInAppName(void) {
    NSString *name = [YTHDefaults() stringForKey:YTHInAppNameKey];
    return name.length ? name : nil;
}

static inline NSInteger YTHDownloadQuality(void) {
    id v = [YTHDefaults() objectForKey:YTHDownloadQualityKey];
    return v ? [v integerValue] : 1080;
}

// Custom in-app logo picked from Photos, stored in Application Support.
static inline NSURL *YTHLogoFileURL(void) {
    NSURL *dir = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    dir = [dir URLByAppendingPathComponent:@"YTHelper" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"logo.png"];
}

// Implemented in Branding.x
extern void YTHBrandingDidChange(void);
// Implemented in Settings.x
extern UIViewController *YTHTopViewController(void);
