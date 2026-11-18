#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface VideoEngine : NSObject
@property(readonly) AVSampleBufferDisplayLayer *displayLayer;
+ (nullable instancetype)makeWithError:(NSError **)error NS_SWIFT_NAME(make());
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithError:(NSError **)error;
- (BOOL)load:(NSString *)path paused:(BOOL)paused;
- (NSDictionary<NSString *,id> *)poll;
- (nullable NSArray<NSDictionary<NSString *,id> *> *)trackList;
- (void)setPictureInPictureDisplayLayer:(nullable AVSampleBufferDisplayLayer *)layer;
- (void)setPaused:(BOOL)paused;
- (void)seek:(double)seconds;
- (BOOL)setNumber:(double)value forOption:(NSString *)option;
- (BOOL)selectTrack:(NSInteger)track property:(NSString *)property;
- (BOOL)addSubtitle:(NSString *)path select:(BOOL)select;
- (void)stop;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
