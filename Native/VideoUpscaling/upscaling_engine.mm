#import "upscaling_engine.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#if !TARGET_OS_SIMULATOR
#import <MetalFX/MetalFX.h>
#endif
#import <VideoToolbox/VideoToolbox.h>

#include <cmath>

@implementation RTCVideoUpscalingConfiguration
+ (BOOL)isBackendSupported:(RTCVideoUpscalingBackend)backend {
    if (backend == RTCVideoUpscalingBackendOff) return YES;

#if !TARGET_OS_SIMULATOR
    if (backend == RTCVideoUpscalingBackendMetalFX) {
        if (@available(iOS 16.0, *)) {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            return device && [MTLFXSpatialScalerDescriptor supportsDevice:device];
        }
    }
    if (backend == RTCVideoUpscalingBackendVideoToolbox) {
        if (@available(iOS 26.0, *)) {
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported;
        }
    }
#endif
    return NO;
}
+ (NSArray<NSNumber *> *)supportedScaleFactorsForBackend:(RTCVideoUpscalingBackend)backend
                                                  width:(NSInteger)width
                                                 height:(NSInteger)height {
    if (![self isBackendSupported:backend]) return @[];
    NSArray<NSNumber *> *scales = @[];
    if (backend == RTCVideoUpscalingBackendMetalFX) scales = @[@1.5, @2, @3, @4];
#if !TARGET_OS_SIMULATOR
    if (backend == RTCVideoUpscalingBackendVideoToolbox && width > 0 && height > 0) {
        if (@available(iOS 26.0, *)) {
            scales = [VTLowLatencySuperResolutionScalerConfiguration
                supportedScaleFactorsForFrameWidth:width frameHeight:height];
        }
    }
#endif
    if (width == 0 && height == 0) return scales;
    if (width <= 0 || height <= 0) return @[];
    return [scales filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSNumber *scale, NSDictionary *bindings) {
            double outputWidth = width * scale.doubleValue;
            double outputHeight = height * scale.doubleValue;
            return fmax(outputWidth, outputHeight) <= 3840 &&
                   fmin(outputWidth, outputHeight) <= 2160 &&
                   std::fmod(outputWidth, 2) == 0 &&
                   std::fmod(outputHeight, 2) == 0;
        }]];
}
- (instancetype)initWithBackend:(RTCVideoUpscalingBackend)backend
                         scale:(double)scale
                   linearColor:(BOOL)linearColor
                 highPrecision:(BOOL)highPrecision {
    if ((self = [super init])) {
        _backend = backend;
        _scale = scale;
        _linearColor = linearColor;
        _highPrecision = highPrecision;
    }
    return self;
}
@end

@implementation RTCVideoUpscalingEngine {
    NSString *_resourceKey;
    NSString *_setupFailure;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    CIContext *_context;
    id _scaler;
    id<MTLTexture> _inputTexture;
    id<MTLTexture> _outputTexture;
    CVPixelBufferPoolRef _outputPool;
    CVPixelBufferPoolRef _videoToolboxInputPool;
    CVPixelBufferPoolRef _videoToolboxOutputPool;
    id _videoToolboxProcessor;
}

- (void)dealloc {
    if (_outputPool) CVPixelBufferPoolRelease(_outputPool);
    if (_videoToolboxInputPool) CVPixelBufferPoolRelease(_videoToolboxInputPool);
    if (_videoToolboxOutputPool) CVPixelBufferPoolRelease(_videoToolboxOutputPool);
    if (@available(iOS 26.0, *)) {
        [(VTFrameProcessor *)_videoToolboxProcessor endSession];
    }
}

- (void)prepareWithWidth:(size_t)width
                  height:(size_t)height
           configuration:(RTCVideoUpscalingConfiguration *)configuration
    API_AVAILABLE(ios(16.0)) {
    if (_outputPool) CVPixelBufferPoolRelease(_outputPool);
    _outputPool = NULL;
    _scaler = nil;
    _inputTexture = nil;
    _outputTexture = nil;
    _setupFailure = nil;
    if (_videoToolboxInputPool) CVPixelBufferPoolRelease(_videoToolboxInputPool);
    if (_videoToolboxOutputPool) CVPixelBufferPoolRelease(_videoToolboxOutputPool);
    _videoToolboxInputPool = NULL;
    _videoToolboxOutputPool = NULL;
    if (@available(iOS 26.0, *)) {
        [(VTFrameProcessor *)_videoToolboxProcessor endSession];
    }
    _videoToolboxProcessor = nil;
    _device = _device ?: MTLCreateSystemDefaultDevice();
    if (!_device) {
        _setupFailure = @"unsupportedHardware";
        return;
    }
    _queue = _queue ?: [_device newCommandQueue];
    _context = _context ?: [CIContext contextWithMTLCommandQueue:_queue];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferWidthKey: @(width * configuration.scale),
        (id)kCVPixelBufferHeightKey: @(height * configuration.scale),
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVReturn result = CVPixelBufferPoolCreate(
        NULL, NULL, (__bridge CFDictionaryRef)attributes, &_outputPool);
    if (result != kCVReturnSuccess || !_queue || !_context) {
        _setupFailure = @"allocationFailed";
        return;
    }
    if (configuration.backend == RTCVideoUpscalingBackendVideoToolbox) {
        [self prepareVideoToolboxWithWidth:width height:height
                            configuration:configuration];
        return;
    }

#if !TARGET_OS_SIMULATOR
    if (configuration.backend != RTCVideoUpscalingBackendMetalFX ||
        ![MTLFXSpatialScalerDescriptor supportsDevice:_device]) {
        _setupFailure = @"unsupportedHardware";
        return;
    }
    MTLFXSpatialScalerDescriptor *descriptor =
        [[MTLFXSpatialScalerDescriptor alloc] init];
    descriptor.inputWidth = width;
    descriptor.inputHeight = height;
    descriptor.outputWidth = width * configuration.scale;
    descriptor.outputHeight = height * configuration.scale;
    descriptor.colorTextureFormat = configuration.highPrecision
        ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    descriptor.outputTextureFormat = descriptor.colorTextureFormat;
    descriptor.colorProcessingMode = configuration.linearColor
        ? MTLFXSpatialScalerColorProcessingModeLinear
        : MTLFXSpatialScalerColorProcessingModePerceptual;
    id<MTLFXSpatialScaler> scaler = [descriptor newSpatialScalerWithDevice:_device];
    _scaler = scaler;
    if (!scaler) {
        _setupFailure = @"setupFailed";
        return;
    }
    MTLTextureDescriptor *texture = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:descriptor.colorTextureFormat
        width:width height:height mipmapped:NO];
    texture.storageMode = MTLStorageModePrivate;
    texture.usage = scaler.colorTextureUsage | MTLTextureUsageShaderRead |
                    MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    _inputTexture = [_device newTextureWithDescriptor:texture];
    texture.width = descriptor.outputWidth;
    texture.height = descriptor.outputHeight;
    texture.usage = scaler.outputTextureUsage | MTLTextureUsageShaderRead |
                    MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    _outputTexture = [_device newTextureWithDescriptor:texture];
    if (!_inputTexture || !_outputTexture) {
        _setupFailure = @"allocationFailed";
    }
#else
    _setupFailure = @"unsupportedHardware";
#endif
}

- (void)prepareVideoToolboxWithWidth:(size_t)width
                             height:(size_t)height
                      configuration:(RTCVideoUpscalingConfiguration *)configuration {
#if !TARGET_OS_SIMULATOR
    if (@available(iOS 26.0, *)) {
        if (!VTLowLatencySuperResolutionScalerConfiguration.isSupported) {
            _setupFailure = @"unsupportedHardware";
            return;
        }
        NSArray<NSNumber *> *scales = [VTLowLatencySuperResolutionScalerConfiguration
            supportedScaleFactorsForFrameWidth:width frameHeight:height];
        if (![scales containsObject:@(configuration.scale)]) {
            _setupFailure = @"unsupportedScale";
            return;
        }
        VTLowLatencySuperResolutionScalerConfiguration *options =
            [[VTLowLatencySuperResolutionScalerConfiguration alloc]
                initWithFrameWidth:width frameHeight:height
                scaleFactor:configuration.scale];
        NSMutableDictionary *source = [options.sourcePixelBufferAttributes mutableCopy];
        NSMutableDictionary *destination =
            [options.destinationPixelBufferAttributes mutableCopy];
        source[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
        destination[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
        CVReturn sourceResult = CVPixelBufferPoolCreate(NULL, NULL,
            (__bridge CFDictionaryRef)source, &_videoToolboxInputPool);
        CVReturn destinationResult = CVPixelBufferPoolCreate(NULL, NULL,
            (__bridge CFDictionaryRef)destination, &_videoToolboxOutputPool);
        if (sourceResult != kCVReturnSuccess || destinationResult != kCVReturnSuccess) {
            _setupFailure = @"allocationFailed";
            return;
        }
        VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
        NSError *error = nil;
        if (![processor startSessionWithConfiguration:options error:&error]) {
            _setupFailure = @"setupFailed";
            return;
        }
        _videoToolboxProcessor = processor;
        return;
    }
#endif
    _setupFailure = @"unsupportedOS";
}

- (CGColorSpaceRef)copyColorSpaceForBuffer:(CVPixelBufferRef)buffer {
    CFDictionaryRef attachments = CVBufferGetAttachments(
        buffer, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRef colorSpace = attachments
        ? CVImageBufferCreateColorSpaceFromAttachments(attachments) : NULL;
    return colorSpace ?: CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
}

- (void)copyAttachmentsFrom:(CVPixelBufferRef)input to:(CVPixelBufferRef)output {
    CVBufferRemoveAllAttachments(output);
    CVBufferPropagateAttachments(input, output);
    NSDictionary *aperture = (__bridge NSDictionary *)CVBufferGetAttachment(
        input, kCVImageBufferCleanApertureKey, NULL);
    if (![aperture isKindOfClass:NSDictionary.class]) return;
    double horizontal = (double)CVPixelBufferGetWidth(output) / CVPixelBufferGetWidth(input);
    double vertical = (double)CVPixelBufferGetHeight(output) / CVPixelBufferGetHeight(input);
    NSMutableDictionary *scaled = [aperture mutableCopy];
    for (NSString *key in @[(id)kCVImageBufferCleanApertureWidthKey,
                            (id)kCVImageBufferCleanApertureHorizontalOffsetKey]) {
        if ([aperture[key] isKindOfClass:NSNumber.class])
            scaled[key] = @([aperture[key] doubleValue] * horizontal);
    }
    for (NSString *key in @[(id)kCVImageBufferCleanApertureHeightKey,
                            (id)kCVImageBufferCleanApertureVerticalOffsetKey]) {
        if ([aperture[key] isKindOfClass:NSNumber.class])
            scaled[key] = @([aperture[key] doubleValue] * vertical);
    }
    CVBufferSetAttachment(output, kCVImageBufferCleanApertureKey,
        (__bridge CFDictionaryRef)scaled, kCVAttachmentMode_ShouldPropagate);
}

- (NSString *)processVideoToolboxInput:(CVPixelBufferRef)input
                               output:(CVPixelBufferRef)output {
#if !TARGET_OS_SIMULATOR
    if (@available(iOS 26.0, *)) {
        CVPixelBufferRef source = NULL;
        CVPixelBufferRef destination = NULL;
        CVReturn sourceResult = CVPixelBufferPoolCreatePixelBuffer(
            NULL, _videoToolboxInputPool, &source);
        CVReturn destinationResult = CVPixelBufferPoolCreatePixelBuffer(
            NULL, _videoToolboxOutputPool, &destination);
        if (sourceResult != kCVReturnSuccess || destinationResult != kCVReturnSuccess) {
            if (source) CVPixelBufferRelease(source);
            if (destination) CVPixelBufferRelease(destination);
            return @"allocationFailed";
        }
        [self copyAttachmentsFrom:input to:source];
        [self copyAttachmentsFrom:input to:destination];
        CGColorSpaceRef color = [self copyColorSpaceForBuffer:input];
        [_context render:[CIImage imageWithCVPixelBuffer:input] toCVPixelBuffer:source
            bounds:CGRectMake(0, 0, CVPixelBufferGetWidth(input),
                CVPixelBufferGetHeight(input)) colorSpace:color];
        VTFrameProcessorFrame *sourceFrame = [[VTFrameProcessorFrame alloc]
            initWithBuffer:source presentationTimeStamp:kCMTimeZero];
        VTFrameProcessorFrame *destinationFrame = [[VTFrameProcessorFrame alloc]
            initWithBuffer:destination presentationTimeStamp:kCMTimeZero];
        NSError *error = nil;
        BOOL succeeded = NO;
        if (sourceFrame && destinationFrame) {
            VTLowLatencySuperResolutionScalerParameters *parameters =
                [[VTLowLatencySuperResolutionScalerParameters alloc]
                    initWithSourceFrame:sourceFrame destinationFrame:destinationFrame];
            succeeded = [(VTFrameProcessor *)_videoToolboxProcessor
                processWithParameters:parameters error:&error];
        }
        if (succeeded) {
            [_context render:[CIImage imageWithCVPixelBuffer:destination]
                toCVPixelBuffer:output bounds:CGRectMake(0, 0,
                    CVPixelBufferGetWidth(output), CVPixelBufferGetHeight(output))
                colorSpace:color];
        }
        CGColorSpaceRelease(color);
        CVPixelBufferRelease(source);
        CVPixelBufferRelease(destination);
        return succeeded ? nil : @"processingFailed";
    }
#endif
    return @"unsupportedOS";
}

- (void)processPixelBuffer:(CVPixelBufferRef)input
            configuration:(RTCVideoUpscalingConfiguration *)configuration
               completion:(void (^)(CVPixelBufferRef, NSString *))completion {
    if (configuration.backend == RTCVideoUpscalingBackendOff) {
        completion(input, nil);
        return;
    }
    if (configuration.backend == RTCVideoUpscalingBackendMetalFX &&
        ![@[@1.5, @2, @3, @4] containsObject:@(configuration.scale)]) {
        completion(input, @"unsupportedScale");
        return;
    }
#if TARGET_OS_SIMULATOR
    completion(input, @"unsupportedHardware");
#else
    CFTypeRef transfer = CVBufferGetAttachment(
        input, kCVImageBufferTransferFunctionKey, NULL);
    if (transfer && (CFEqual(transfer,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
        CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG))) {
        completion(input, @"hdrInput");
        return;
    }
    OSType format = CVPixelBufferGetPixelFormatType(input);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        format != kCVPixelFormatType_32BGRA) {
        completion(input, @"unsupportedFormat");
        return;
    }
    size_t width = CVPixelBufferGetWidth(input);
    size_t height = CVPixelBufferGetHeight(input);
    double outputWidth = width * configuration.scale;
    double outputHeight = height * configuration.scale;
    if (!std::isfinite(configuration.scale) || configuration.scale <= 1 ||
        std::fmod(outputWidth, 2) || std::fmod(outputHeight, 2)) {
        completion(input, @"unsupportedDimensions");
        return;
    }
    if (fmax(outputWidth, outputHeight) > 3840 ||
        fmin(outputWidth, outputHeight) > 2160) {
        completion(input, @"outputLimit");
        return;
    }
    if (@available(iOS 16.0, *)) {
        NSString *key = [NSString stringWithFormat:@"%zu:%zu:%u:%ld:%g:%d:%d:%@",
            width, height, format, (long)configuration.backend,
            configuration.scale, configuration.linearColor,
            configuration.highPrecision,
            (__bridge id)CVBufferGetAttachments(input,
                kCVAttachmentMode_ShouldPropagate)];
        if (![_resourceKey isEqual:key]) {
            _resourceKey = key;
            [self prepareWithWidth:width height:height configuration:configuration];
        }
        if (_setupFailure) {
            completion(input, _setupFailure);
            return;
        }
        CVPixelBufferRef output = NULL;
        NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @3};
        CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            NULL, _outputPool, (__bridge CFDictionaryRef)limit, &output);
        if (result != kCVReturnSuccess) {
            completion(input, @"allocationFailed");
            return;
        }
        [self copyAttachmentsFrom:input to:output];
        if (configuration.backend == RTCVideoUpscalingBackendVideoToolbox) {
            NSString *reason = [self processVideoToolboxInput:input output:output];
            completion(reason ? input : output, reason);
            CVPixelBufferRelease(output);
            return;
        }
        CGColorSpaceRef workingColor = CGColorSpaceCreateWithName(
            configuration.linearColor ? kCGColorSpaceLinearSRGB : kCGColorSpaceSRGB);
        id<MTLCommandBuffer> command = [_queue commandBuffer];
        [_context render:[CIImage imageWithCVPixelBuffer:input]
            toMTLTexture:_inputTexture commandBuffer:command
            bounds:CGRectMake(0, 0, width, height) colorSpace:workingColor];
        id<MTLFXSpatialScaler> scaler = _scaler;
        scaler.inputContentWidth = width;
        scaler.inputContentHeight = height;
        scaler.colorTexture = _inputTexture;
        scaler.outputTexture = _outputTexture;
        [scaler encodeToCommandBuffer:command];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            completion(input, @"processingFailed");
        } else {
            CIImage *image = [CIImage imageWithMTLTexture:_outputTexture
                options:@{kCIImageColorSpace: (__bridge id)workingColor}];
            CGColorSpaceRef outputColor = [self copyColorSpaceForBuffer:input];
            [_context render:image toCVPixelBuffer:output
                bounds:CGRectMake(0, 0, outputWidth, outputHeight)
                colorSpace:outputColor];
            CGColorSpaceRelease(outputColor);
            completion(output, nil);
        }
        CGColorSpaceRelease(workingColor);
        CVPixelBufferRelease(output);
    } else {
        completion(input, @"unsupportedOS");
    }
#endif
}
@end
