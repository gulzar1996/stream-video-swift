#import "RTCVideoUpscaling.h"

NS_ASSUME_NONNULL_BEGIN

/// One engine is used serially by one receiver's processing queue.
@interface RTCVideoUpscalingEngine : NSObject
/// The output is borrowed for the duration of the callback.
- (void)processPixelBuffer:(CVPixelBufferRef)input
            configuration:(RTCVideoUpscalingConfiguration *)configuration
               completion:(void (^)(CVPixelBufferRef output,
                                    NSString *_Nullable reason))completion;
@end

NS_ASSUME_NONNULL_END
