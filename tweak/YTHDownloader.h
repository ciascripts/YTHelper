#import <UIKit/UIKit.h>

// A single downloadable stream (one DASH track or one progressive file).
@interface YTHStream : NSObject
@property (nonatomic, assign) int itag;
@property (nonatomic, strong) NSURL *URL;
@property (nonatomic, copy) NSString *userAgent; // sent with the download when set
@end

// Downloads a video (separate H.264 video + AAC audio, or audio only), merges it with
// AVFoundation and shows the share sheet so the user can save it to Photos or Files.
@interface YTHDownloader : NSObject
+ (BOOL)isBusy;
// streams: every stream the player knows about. maxHeight: 0 means audio only.
// videoID: when the streams have no usable links (YouTube's SABR streaming), links are fetched
// from YouTube's player API for this ID instead. Pass nil to skip that.
+ (void)downloadTitle:(NSString *)title videoID:(NSString *)videoID streams:(NSArray<YTHStream *> *)streams maxHeight:(NSInteger)maxHeight presenter:(UIViewController *)presenter;
@end
