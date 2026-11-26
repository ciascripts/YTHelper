// Background playback for YTHelper: keeps videos playing with the screen off or in another app.
// Hooks adapted from YouTube-X by PoomSmart (MIT License, https://github.com/PoomSmart/YouTube-X,
// commit 9a8e60a488325e37cf69e0611811889ab37cd3d3). See NOTICE.
// Only initialised when "Background play" is on, so changes need an app restart.
#import "Prefs.h"

%group YTHBackground

%hook YTIPlayabilityStatus
- (BOOL)isPlayableInBackground { return YES; }
%end

%hook MLVideo
- (BOOL)playableInBackground { return YES; }
%end

%hook YTIBackgroundOfflineSettingCategoryEntryRenderer
%new(B@:)
- (BOOL)isBackgroundEnabled { return YES; }
%end

%end

%ctor {
    if (YTHBackgroundPlay()) {
        %init(YTHBackground);
    }
}
