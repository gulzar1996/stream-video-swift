#import "upscaling_engine.h"

NS_ASSUME_NONNULL_BEGIN

/// Serializes frame delivery while processing runs on a separate queue.
@interface RTCVideoUpscalingProcessor : NSObject
- (instancetype)initWithEngine:(RTCVideoUpscalingEngine *)engine;
- (void)configure:(RTCVideoUpscalingConfiguration *)configuration;
- (void)configure:(RTCVideoUpscalingConfiguration *)configuration
    statusHandler:(nullable void (^)(RTCVideoUpscalingStatus *status))statusHandler;
/// The provider returns a retained buffer. Nil output means passthrough.
- (void)submitWithWidth:(size_t)width
                height:(size_t)height
              provider:(CVPixelBufferRef _Nullable (^)(void))provider
            completion:(void (^)(CVPixelBufferRef _Nullable output))completion;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
