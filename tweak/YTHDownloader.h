#import <UIKit/UIKit.h>

// A single downloadable stream (one DASH track or one progressive file).
@interface YTHStream : NSObject
@property (nonatomic, assign) int itag;
@property (nonatomic, strong) NSURL *URL;
@end

// Downloads a video (separate H.264 video + AAC audio, or audio only), merges it with
// AVFoundation and shows the share sheet so the user can save it to Photos or Files.
@interface YTHDownloader : NSObject
+ (BOOL)isBusy;
// streams: every stream the player knows about. maxHeight: 0 means audio only.
+ (void)downloadTitle:(NSString *)title streams:(NSArray<YTHStream *> *)streams maxHeight:(NSInteger)maxHeight presenter:(UIViewController *)presenter;
@end
