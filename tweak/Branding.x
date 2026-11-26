// In-app name and logo: replaces the YouTube wordmark in the top bar with either a custom
// picture (picked in Settings) or the custom in-app name rendered as text.
#import <objc/runtime.h>
#import "Prefs.h"

static UIImage *gCustomLogo;          // cached custom picture
static UIImage *gNameLogoLight;       // cached rendered name, dark text (light mode)
static UIImage *gNameLogoDark;        // cached rendered name, white text (dark mode)
static NSHashTable<UIImageView *> *gLogoViews; // logo views we have touched, to refresh live

static UIImage *YTHRenderName(NSString *name, UIColor *color, CGFloat height) {
    UIFont *font = [UIFont systemFontOfSize:height * 0.9 weight:UIFontWeightBold];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
    CGSize size = [name sizeWithAttributes:attrs];
    size = CGSizeMake(ceil(MIN(size.width, 220)), height);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGSize text = [name sizeWithAttributes:attrs];
        [name drawInRect:CGRectMake(0, (height - text.height) / 2, size.width, text.height) withAttributes:attrs];
    }];
}

static UIImage *YTHCustomLogo(void) {
    if (!gCustomLogo && [YTHDefaults() boolForKey:YTHUseCustomLogoKey]) {
        NSData *data = [NSData dataWithContentsOfURL:YTHLogoFileURL()];
        if (data) gCustomLogo = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
    }
    return gCustomLogo;
}

// Returns the replacement for a YouTube logo image, or nil to keep the original.
static UIImage *YTHReplacementLogo(UIImage *original, BOOL darkVariant) {
    CGFloat height = original.size.height > 0 ? original.size.height : 20;
    UIImage *custom = YTHCustomLogo();
    if (custom) {
        // Scale the picture to the wordmark's height, keeping its aspect ratio.
        CGFloat w = MIN(custom.size.width * height / MAX(custom.size.height, 1), 220);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, height)];
        return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [custom drawInRect:CGRectMake(0, 0, w, height)];
        }];
    }
    NSString *name = YTHInAppName();
    if (!name) return nil;
    if (darkVariant) {
        if (!gNameLogoDark) gNameLogoDark = YTHRenderName(name, UIColor.whiteColor, height);
        return gNameLogoDark;
    }
    if (!gNameLogoLight) gNameLogoLight = YTHRenderName(name, UIColor.blackColor, height);
    return gNameLogoLight;
}

void YTHBrandingDidChange(void) {
    gCustomLogo = gNameLogoLight = gNameLogoDark = nil;
    for (UIImageView *view in gLogoViews.allObjects) {
        UIImage *original = objc_getAssociatedObject(view, @selector(YTHBrandingDidChange));
        if (original) view.image = original; // setImage: hook below re-applies the replacement
    }
}

%hook UIImageView

- (void)setImage:(UIImage *)image {
    // YouTube's wordmark images describe themselves as "...Resources: youtube_logo)" and
    // "...Resources: youtube_logo_dark)". Anything else passes straight through.
    if (image) {
        NSString *desc = image.description;
        BOOL isLogo = [desc containsString:@"Resources: youtube_logo)"];
        BOOL isDarkLogo = [desc containsString:@"Resources: youtube_logo_dark)"];
        if (isLogo || isDarkLogo) {
            objc_setAssociatedObject(self, @selector(YTHBrandingDidChange), image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [gLogoViews addObject:self];
            UIImage *replacement = YTHReplacementLogo(image, isDarkLogo);
            if (replacement) {
                self.contentMode = UIViewContentModeScaleAspectFit;
                return %orig(replacement);
            }
        }
    }
    %orig;
}

%end

%ctor {
    gLogoViews = [NSHashTable weakObjectsHashTable];
    %init;
}
