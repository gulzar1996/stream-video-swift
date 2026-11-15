#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RTCVideoUpscalingBackend) {
    RTCVideoUpscalingBackendOff,
    RTCVideoUpscalingBackendVideoToolbox,
    RTCVideoUpscalingBackendMetalFX
};

/// Immutable options for processing received video.
__attribute__((visibility("default")))
@interface RTCVideoUpscalingConfiguration : NSObject
@property(nonatomic, readonly) RTCVideoUpscalingBackend backend;
@property(nonatomic, readonly) double scale;
@property(nonatomic, readonly) BOOL linearColor;
@property(nonatomic, readonly) BOOL highPrecision;
- (instancetype)initWithBackend:(RTCVideoUpscalingBackend)backend
                         scale:(double)scale
                   linearColor:(BOOL)linearColor
                 highPrecision:(BOOL)highPrecision;
+ (BOOL)isBackendSupported:(RTCVideoUpscalingBackend)backend;
+ (NSArray<NSNumber *> *)supportedScaleFactorsForBackend:(RTCVideoUpscalingBackend)backend
                                                  width:(NSInteger)width
                                                 height:(NSInteger)height;
@end

typedef NS_ENUM(NSInteger, RTCVideoUpscalingState) {
    RTCVideoUpscalingStatePreparing,
    RTCVideoUpscalingStateActive,
    RTCVideoUpscalingStatePassthrough
};

/// A snapshot of one receiver's requested and effective processing state.
__attribute__((visibility("default")))
@interface RTCVideoUpscalingStatus : NSObject
@property(nonatomic, readonly) RTCVideoUpscalingConfiguration *configuration;
@property(nonatomic, readonly) uint64_t sequence;
@property(nonatomic, readonly) RTCVideoUpscalingBackend effectiveBackend;
@property(nonatomic, readonly) RTCVideoUpscalingState state;
@property(nonatomic, readonly, nullable) NSString *fallbackReason;
@property(nonatomic, readonly) NSInteger inputWidth;
@property(nonatomic, readonly) NSInteger inputHeight;
@property(nonatomic, readonly) NSInteger outputWidth;
@property(nonatomic, readonly) NSInteger outputHeight;
@property(nonatomic, readonly) double processingMilliseconds;
@property(nonatomic, readonly) uint64_t enhancedFrames;
@property(nonatomic, readonly) uint64_t bypassedFrames;
@end

NS_ASSUME_NONNULL_END
