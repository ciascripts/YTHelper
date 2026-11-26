// YTHelper section in YouTube Settings.
// Section registration follows the pattern used by PoomSmart's YTUHD (MIT) and works with
// YouGroupSettings (MIT), which shows tweak sections under a "Tweaks" group.
#import <objc/runtime.h>
#import <PhotosUI/PhotosUI.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTUIUtils.h>
#import "Prefs.h"

#define TweakName @"YTHelper"
static const NSInteger TweakSection = 'ythp';

@interface YTSettingsSectionItemManager (YTHelper)
- (void)updateYTHelperSectionWithEntry:(id)entry;
@end

@interface YTSettingsGroupData (YTHelper)
+ (NSMutableArray <NSNumber *> *)tweaks; // added by YouGroupSettings
@end

UIViewController *YTHTopViewController(void) {
    UIViewController *vc = nil;
    Class utils = %c(YTUIUtils);
    if ([utils respondsToSelector:@selector(topViewControllerForPresenting)])
        vc = [utils topViewControllerForPresenting];
    if (!vc) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows)
                if (w.isKeyWindow) vc = w.rootViewController;
        }
        while (vc.presentedViewController) vc = vc.presentedViewController;
    }
    return vc;
}

// ---------- Photos picker for the in-app logo ----------
@interface YTHLogoPicker : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, copy) void (^completion)(BOOL saved);
@end

@implementation YTHLogoPicker
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider) return; // user cancelled
    if (![provider canLoadObjectOfClass:UIImage.class]) { if (self.completion) self.completion(NO); return; }
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        UIImage *image = (UIImage *)object;
        BOOL ok = NO;
        if ([image isKindOfClass:UIImage.class]) {
            // Store at most 600px tall so the top bar stays sharp without wasting memory.
            CGFloat scale = MIN(1, 600 / MAX(image.size.height, 1));
            CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
            UIImage *resized = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
            }];
            ok = [UIImagePNGRepresentation(resized) writeToURL:YTHLogoFileURL() atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) [YTHDefaults() setBool:YES forKey:YTHUseCustomLogoKey];
            if (self.completion) self.completion(ok);
        });
    }];
}
@end

static YTHLogoPicker *gLogoPicker;

static void YTHAlert(NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [YTHTopViewController() presentViewController:a animated:YES completion:nil];
}

// Alternate Home Screen icons that the build workflow added to Info.plist.
static NSArray<NSString *> *YTHAlternateIconNames(void) {
    NSDictionary *icons = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"];
    NSDictionary *alts = icons[@"CFBundleAlternateIcons"];
    return [alts.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)] ?: @[];
}

static NSString *YTHQualityLabel(NSInteger q) {
    return q == YTHDownloadAudioOnly ? @"Audio only" : [NSString stringWithFormat:@"Up to %ldp", (long)q];
}

%hook YTSettingsGroupData

// Without YouGroupSettings (older layouts), put our section first in the main list.
- (NSArray <NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSMutableArray *categories = [%orig mutableCopy];
    [categories insertObject:@(TweakSection) atIndex:0];
    return categories.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    NSArray <NSNumber *> *order = %orig;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex == NSNotFound || [order containsObject:@(TweakSection)]) return order;
    NSMutableArray *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateYTHelperSectionWithEntry:(id)entry {
    NSMutableArray <YTSettingsSectionItem *> *items = [NSMutableArray array];
    Class Item = %c(YTSettingsSectionItem);
    YTSettingsViewController *settingsVC = [self valueForKey:@"_settingsViewControllerDelegate"];
    __weak YTSettingsViewController *weakVC = settingsVC;

    // Block ads
    [items addObject:[Item switchItemWithTitle:@"Block ads"
        titleDescription:@"Removes video, feed, Shorts and shopping ads. Restart the app after changing."
        accessibilityIdentifier:nil
        switchOn:YTHBlockAds()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [YTHDefaults() setBool:enabled forKey:YTHBlockAdsKey];
            return YES;
        }
        settingItemId:0]];

    // In-app name
    [items addObject:[Item itemWithTitle:@"In-app name"
        titleDescription:@"Replaces the YouTube logo in the top bar with this text. Leave empty to keep the logo."
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() { return YTHInAppName() ?: @"YouTube"; }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"In-app name" message:nil preferredStyle:UIAlertControllerStyleAlert];
            [a addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.text = YTHInAppName();
                field.placeholder = @"YouTube";
                field.clearButtonMode = UITextFieldViewModeWhileEditing;
            }];
            [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            __weak UIAlertController *weakAlert = a;
            [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (name.length > 30) name = [name substringToIndex:30];
                if (name.length) [YTHDefaults() setObject:name forKey:YTHInAppNameKey];
                else [YTHDefaults() removeObjectForKey:YTHInAppNameKey];
                YTHBrandingDidChange();
                [weakVC reloadData];
            }]];
            [YTHTopViewController() presentViewController:a animated:YES completion:nil];
            return YES;
        }]];

    // In-app logo
    BOOL hasLogo = [YTHDefaults() boolForKey:YTHUseCustomLogoKey];
    [items addObject:[Item itemWithTitle:@"In-app logo"
        titleDescription:@"Pick a picture to show instead of the YouTube logo. It takes priority over the in-app name."
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() { return hasLogo ? @"Custom" : @"Default"; }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg) {
            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.filter = [PHPickerFilter imagesFilter];
            config.selectionLimit = 1;
            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
            gLogoPicker = [YTHLogoPicker new];
            gLogoPicker.completion = ^(BOOL saved) {
                if (!saved) { YTHAlert(@"Couldn't use that picture", @"Try a different image."); return; }
                YTHBrandingDidChange();
                [weakVC reloadData];
            };
            picker.delegate = gLogoPicker;
            [YTHTopViewController() presentViewController:picker animated:YES completion:nil];
            return YES;
        }]];
    if (hasLogo) {
        [items addObject:[Item itemWithTitle:@"Reset in-app logo"
            titleDescription:nil
            accessibilityIdentifier:nil
            detailTextBlock:nil
            selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg) {
                [YTHDefaults() setBool:NO forKey:YTHUseCustomLogoKey];
                [[NSFileManager defaultManager] removeItemAtURL:YTHLogoFileURL() error:nil];
                YTHBrandingDidChange();
                [weakVC reloadData];
                return YES;
            }]];
    }

    // Home Screen icon (alternate icons bundled at build time)
    NSArray<NSString *> *altIcons = YTHAlternateIconNames();
    NSString *homeName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"YouTube";
    [items addObject:[Item itemWithTitle:@"Home Screen icon"
        titleDescription:[NSString stringWithFormat:@"Home Screen name: %@ (set when building the IPA).%@", homeName,
            altIcons.count ? @"" : @"\nNo extra icons in this build. Add some with alt_icon_urls when you build the IPA."]
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() { return UIApplication.sharedApplication.alternateIconName ?: @"Default"; }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg) {
            if (!altIcons.count || !UIApplication.sharedApplication.supportsAlternateIcons) {
                YTHAlert(@"No extra icons", @"This build only has its main icon. Rebuild the IPA with alt_icon_urls to add choices.");
                return YES;
            }
            NSMutableArray *rows = [NSMutableArray array];
            NSArray *names = [@[@"Default"] arrayByAddingObjectsFromArray:altIcons];
            for (NSString *name in names) {
                [rows addObject:[Item checkmarkItemWithTitle:name titleDescription:nil selectBlock:^BOOL (YTSettingsCell *c, NSUInteger i) {
                    NSString *iconName = [name isEqualToString:@"Default"] ? nil : name;
                    [UIApplication.sharedApplication setAlternateIconName:iconName completionHandler:^(NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (error) YTHAlert(@"Couldn't change the icon", error.localizedDescription);
                            [weakVC reloadData];
                        });
                    }];
                    return YES;
                }]];
            }
            NSString *current = UIApplication.sharedApplication.alternateIconName;
            NSUInteger selected = current ? [names indexOfObject:current] : 0;
            if (selected == NSNotFound) selected = 0;
            YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc] initWithNavTitle:@"Home Screen icon" pickerSectionTitle:nil rows:rows selectedItemIndex:selected parentResponder:[self parentResponder]];
            [weakVC pushViewController:picker];
            return YES;
        }]];

    // Download quality
    [items addObject:[Item itemWithTitle:@"Download quality"
        titleDescription:@"Used by the download button on the video player. Downloads are H.264 + AAC (MP4)."
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() { return YTHQualityLabel(YTHDownloadQuality()); }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg) {
            NSArray<NSNumber *> *values = @[@1080, @720, @480, @360, @(YTHDownloadAudioOnly)];
            NSMutableArray *rows = [NSMutableArray array];
            for (NSNumber *value in values) {
                [rows addObject:[Item checkmarkItemWithTitle:YTHQualityLabel(value.integerValue) titleDescription:nil selectBlock:^BOOL (YTSettingsCell *c, NSUInteger i) {
                    [YTHDefaults() setInteger:value.integerValue forKey:YTHDownloadQualityKey];
                    [weakVC reloadData];
                    return YES;
                }]];
            }
            NSUInteger selected = [values indexOfObject:@(YTHDownloadQuality())];
            YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc] initWithNavTitle:@"Download quality" pickerSectionTitle:nil rows:rows selectedItemIndex:(selected == NSNotFound ? 0 : selected) parentResponder:[self parentResponder]];
            [weakVC pushViewController:picker];
            return YES;
        }]];

    if ([settingsVC respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [settingsVC setSectionItems:items forCategory:TweakSection title:TweakName icon:nil titleDescription:nil headerHidden:NO];
    else
        [settingsVC setSectionItems:items forCategory:TweakSection title:TweakName titleDescription:nil headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == TweakSection) {
        [self updateYTHelperSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end

%ctor {
    %init;
    // Register with YouGroupSettings once every injected dylib has loaded.
    dispatch_async(dispatch_get_main_queue(), ^{
        Class groupData = objc_getClass("YTSettingsGroupData");
        if (class_getClassMethod(groupData, @selector(tweaks))) {
            NSMutableArray *tweaks = [groupData tweaks];
            if (![tweaks containsObject:@(TweakSection)]) [tweaks insertObject:@(TweakSection) atIndex:0];
        }
    });
}
