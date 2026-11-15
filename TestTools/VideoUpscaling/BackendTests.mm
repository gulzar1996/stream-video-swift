#import <XCTest/XCTest.h>
#import <VideoToolbox/VideoToolbox.h>
#import "upscaling_engine.h"

@interface BackendTests : XCTestCase
@end

@implementation BackendTests

- (void)testCapabilitiesMatchDeviceSupportAndOutputBounds {
    XCTAssertTrue([RTCVideoUpscalingConfiguration isBackendSupported:RTCVideoUpscalingBackendOff]);
    XCTAssertTrue([RTCVideoUpscalingConfiguration isBackendSupported:RTCVideoUpscalingBackendMetalFX]);
    XCTAssertEqualObjects([RTCVideoUpscalingConfiguration
        supportedScaleFactorsForBackend:RTCVideoUpscalingBackendMetalFX
        width:320 height:180], (@[@1.5, @2, @3, @4]));
    XCTAssertEqualObjects([RTCVideoUpscalingConfiguration
        supportedScaleFactorsForBackend:RTCVideoUpscalingBackendMetalFX
        width:1920 height:1080], (@[@1.5, @2]));
    if (@available(iOS 26.0, *)) {
        XCTAssertEqual([RTCVideoUpscalingConfiguration
            isBackendSupported:RTCVideoUpscalingBackendVideoToolbox],
            VTLowLatencySuperResolutionScalerConfiguration.isSupported);
    }
}

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width
                                  height:(size_t)height {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVReturn result = CVPixelBufferCreate(
        NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (__bridge CFDictionaryRef)attributes, &buffer);
    XCTAssertEqual(result, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(buffer, 0);
    for (size_t plane = 0; plane < 2; ++plane) {
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
               plane == 0 ? 100 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) *
                   CVPixelBufferGetHeightOfPlane(buffer, plane));
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

- (void)testScaledOutputPreservesCleanApertureAndPixelAspectRatio {
    RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
    CVPixelBufferRef input = [self createBufferWithWidth:320 height:180];
    NSDictionary *aperture = @{
        (id)kCVImageBufferCleanApertureWidthKey: @300,
        (id)kCVImageBufferCleanApertureHeightKey: @160,
        (id)kCVImageBufferCleanApertureHorizontalOffsetKey: @4,
        (id)kCVImageBufferCleanApertureVerticalOffsetKey: @2
    };
    NSDictionary *aspect = @{
        (id)kCVImageBufferPixelAspectRatioHorizontalSpacingKey: @4,
        (id)kCVImageBufferPixelAspectRatioVerticalSpacingKey: @3
    };
    CVBufferSetAttachment(input, kCVImageBufferCleanApertureKey,
        (__bridge CFDictionaryRef)aperture, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey,
        (__bridge CFDictionaryRef)aspect, kCVAttachmentMode_ShouldPropagate);
    [subject processPixelBuffer:input configuration:
        [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendMetalFX scale:2
            linearColor:NO highPrecision:NO]
        completion:^(CVPixelBufferRef output, NSString *reason) {
            XCTAssertNil(reason);
            NSDictionary *scaled = (__bridge NSDictionary *)CVBufferGetAttachment(
                output, kCVImageBufferCleanApertureKey, NULL);
            for (NSString *key in aperture) {
                XCTAssertEqualWithAccuracy([scaled[key] doubleValue],
                    [aperture[key] doubleValue] * 2, 0.001);
            }
            XCTAssertEqualObjects((__bridge id)CVBufferGetAttachment(
                output, kCVImageBufferPixelAspectRatioKey, NULL), aspect);
        }];
    CVPixelBufferRelease(input);
}

- (void)testMetalFXProducesScaledNV12AndPreservesColor {
    RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
    CVPixelBufferRef input = [self createBufferWithWidth:320 height:180];
    XCTestExpectation *finished = [self expectationWithDescription:@"processed"];
    RTCVideoUpscalingConfiguration *configuration =
        [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendMetalFX scale:2
            linearColor:NO highPrecision:NO];
    [subject processPixelBuffer:input configuration:configuration completion:
        ^(CVPixelBufferRef output, NSString *reason) {
            XCTAssertNil(reason);
            XCTAssertEqual(CVPixelBufferGetWidth(output), 640);
            XCTAssertEqual(CVPixelBufferGetHeight(output), 360);
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output),
                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
            XCTAssertEqualObjects((__bridge id)CVBufferGetAttachment(
                output, kCVImageBufferColorPrimariesKey, NULL),
                (__bridge id)kCVImageBufferColorPrimaries_ITU_R_709_2);
            CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
            uint8_t *luma = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output, 0);
            XCTAssertEqualWithAccuracy(luma[100], 100, 5);
            CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
            [finished fulfill];
        }];
    [self waitForExpectations:@[finished] timeout:30];
    CVPixelBufferRelease(input);
}

- (void)testMetalFXColorAndOptionsSurviveResolutionChanges {
    RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
    for (NSNumber *scale in @[@1.5, @2, @3, @4]) {
        for (NSNumber *linear in @[@NO, @YES]) {
            for (NSNumber *precision in @[@NO, @YES]) {
                size_t width = linear.boolValue ? 180 : 320;
                size_t height = linear.boolValue ? 320 : 180;
                CVPixelBufferRef input = [self createBufferWithWidth:width height:height];
                CVPixelBufferLockBaseAddress(input, 0);
                uint8_t *chroma = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, 1);
                size_t stride = CVPixelBufferGetBytesPerRowOfPlane(input, 1);
                for (size_t y = 0; y < height / 2; ++y) {
                    for (size_t x = 0; x < width; x += 2) {
                        chroma[y * stride + x] = 90;
                        chroma[y * stride + x + 1] = 170;
                    }
                }
                CVPixelBufferUnlockBaseAddress(input, 0);
                [subject processPixelBuffer:input configuration:
                    [[RTCVideoUpscalingConfiguration alloc]
                        initWithBackend:RTCVideoUpscalingBackendMetalFX
                        scale:scale.doubleValue linearColor:linear.boolValue
                        highPrecision:precision.boolValue]
                    completion:^(CVPixelBufferRef output, NSString *reason) {
                        XCTAssertNil(reason);
                        XCTAssertEqual(CVPixelBufferGetWidth(output), width * scale.doubleValue);
                        XCTAssertEqual(CVPixelBufferGetHeight(output), height * scale.doubleValue);
                        CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
                        uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output, 0);
                        uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(output, 1);
                        XCTAssertEqualWithAccuracy(y[100], 100, 5);
                        XCTAssertEqualWithAccuracy(uv[100], 90, 5);
                        XCTAssertEqualWithAccuracy(uv[101], 170, 5);
                        CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
                    }];
                CVPixelBufferRelease(input);
            }
        }
    }
}

- (void)testMetalFXRejectsScaleOutsideAdvertisedChoices {
    RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
    CVPixelBufferRef input = [self createBufferWithWidth:320 height:180];
    [subject processPixelBuffer:input configuration:
        [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendMetalFX scale:1.7
            linearColor:NO highPrecision:NO]
        completion:^(CVPixelBufferRef output, NSString *reason) {
            XCTAssertEqual(output, input);
            XCTAssertEqualObjects(reason, @"unsupportedScale");
        }];
    CVPixelBufferRelease(input);
}

- (void)testHDRIsUnchangedAndReported {
    RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
    CVPixelBufferRef input = [self createBufferWithWidth:320 height:180];
    CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                          kCVAttachmentMode_ShouldPropagate);
    XCTestExpectation *finished = [self expectationWithDescription:@"fallback"];
    RTCVideoUpscalingConfiguration *configuration =
        [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendMetalFX scale:2
            linearColor:NO highPrecision:NO];
    [subject processPixelBuffer:input configuration:configuration completion:
        ^(CVPixelBufferRef output, NSString *reason) {
            XCTAssertEqual(input, output);
            XCTAssertEqualObjects(reason, @"hdrInput");
            [finished fulfill];
        }];
    [self waitForExpectations:@[finished] timeout:5];
    CVPixelBufferRelease(input);
}

- (void)testOutputLimitPassesThroughWithoutDownscaling {
    RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
    CVPixelBufferRef input = [self createBufferWithWidth:1920 height:1080];
    XCTestExpectation *finished = [self expectationWithDescription:@"fallback"];
    RTCVideoUpscalingConfiguration *configuration =
        [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendMetalFX scale:3
            linearColor:NO highPrecision:NO];
    [subject processPixelBuffer:input configuration:configuration completion:
        ^(CVPixelBufferRef output, NSString *reason) {
            XCTAssertEqual(input, output);
            XCTAssertEqualObjects(reason, @"outputLimit");
            [finished fulfill];
        }];
    [self waitForExpectations:@[finished] timeout:5];
    CVPixelBufferRelease(input);
}

- (void)testVideoToolboxRejectsAnUnsupportedScaleWithoutSwitchingBackend {
    if (@available(iOS 26.0, *)) {
        NSArray<NSNumber *> *scales = [VTLowLatencySuperResolutionScalerConfiguration
            supportedScaleFactorsForFrameWidth:640 frameHeight:360];
        double unsupported = [scales containsObject:@1.5] ? 3 : 1.5;
        XCTAssertFalse([scales containsObject:@(unsupported)]);
        RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
        CVPixelBufferRef input = [self createBufferWithWidth:640 height:360];
        XCTestExpectation *finished = [self expectationWithDescription:@"fallback"];
        RTCVideoUpscalingConfiguration *configuration =
            [[RTCVideoUpscalingConfiguration alloc]
                initWithBackend:RTCVideoUpscalingBackendVideoToolbox
                scale:unsupported linearColor:NO highPrecision:NO];
        [subject processPixelBuffer:input configuration:configuration completion:
            ^(CVPixelBufferRef output, NSString *reason) {
                XCTAssertEqual(output, input);
                XCTAssertEqualObjects(reason, @"unsupportedScale");
                [finished fulfill];
            }];
        [self waitForExpectations:@[finished] timeout:30];
        CVPixelBufferRelease(input);
    }
}

- (void)testVideoToolboxProducesActualOutput {
    if (@available(iOS 26.0, *)) {
        XCTAssertTrue(VTLowLatencySuperResolutionScalerConfiguration.isSupported);
        NSArray<NSNumber *> *scales = [VTLowLatencySuperResolutionScalerConfiguration
            supportedScaleFactorsForFrameWidth:640 frameHeight:360];
        XCTAssertTrue([scales containsObject:@2]);
        RTCVideoUpscalingEngine *subject = [[RTCVideoUpscalingEngine alloc] init];
        CVPixelBufferRef input = [self createBufferWithWidth:640 height:360];
        XCTestExpectation *finished = [self expectationWithDescription:@"processed"];
        RTCVideoUpscalingConfiguration *configuration =
            [[RTCVideoUpscalingConfiguration alloc]
                initWithBackend:RTCVideoUpscalingBackendVideoToolbox scale:2
                linearColor:NO highPrecision:NO];
        [subject processPixelBuffer:input configuration:configuration completion:
            ^(CVPixelBufferRef output, NSString *reason) {
                XCTAssertNil(reason);
                XCTAssertEqual(CVPixelBufferGetWidth(output), 1280);
                XCTAssertEqual(CVPixelBufferGetHeight(output), 720);
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(output),
                               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
                [finished fulfill];
            }];
        [self waitForExpectations:@[finished] timeout:30];
        CVPixelBufferRelease(input);
    }
}

@end
