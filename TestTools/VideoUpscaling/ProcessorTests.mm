#import <XCTest/XCTest.h>
#import "upscaling_processor.h"

@interface HeldUpscalingEngine : RTCVideoUpscalingEngine
@property(nonatomic, copy) void (^started)(void);
@property(nonatomic, copy) void (^finish)(CVPixelBufferRef, NSString *);
@end

@implementation HeldUpscalingEngine
- (void)processPixelBuffer:(CVPixelBufferRef)input
            configuration:(RTCVideoUpscalingConfiguration *)configuration
               completion:(void (^)(CVPixelBufferRef, NSString *))completion {
    XCTAssertFalse(NSThread.isMainThread);
    self.finish = completion;
    self.started();
}
@end

@interface ProcessorTests : XCTestCase
@property(nonatomic, strong) RTCVideoUpscalingProcessor *subject;
@property(nonatomic, strong) HeldUpscalingEngine *engine;
@property(nonatomic, assign) CVPixelBufferRef input;
@end

@implementation ProcessorTests
- (void)setUp {
    [super setUp];
    self.engine = [[HeldUpscalingEngine alloc] init];
    self.subject = [[RTCVideoUpscalingProcessor alloc] initWithEngine:self.engine];
    CVPixelBufferRef input = NULL;
    XCTAssertEqual(CVPixelBufferCreate(NULL, 320, 180,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &input),
        kCVReturnSuccess);
    self.input = input;
}

- (void)tearDown {
    [self.subject stop];
    self.subject = nil;
    self.engine.finish = nil;
    self.engine.started = nil;
    self.engine = nil;
    CVPixelBufferRelease(self.input);
    self.input = NULL;
    [super tearDown];
}

- (RTCVideoUpscalingConfiguration *)enabled {
    return [[RTCVideoUpscalingConfiguration alloc]
        initWithBackend:RTCVideoUpscalingBackendMetalFX scale:2
        linearColor:NO highPrecision:NO];
}

- (void)testOffDeliversOriginalWithoutConvertingInput {
    XCTestExpectation *delivered = [self expectationWithDescription:@"original"];
    [self.subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
        XCTFail(@"Off must not convert input");
        return NULL;
    } completion:^(CVPixelBufferRef output) {
        XCTAssertTrue(output == nullptr);
        [delivered fulfill];
    }];
    [self waitForExpectations:@[delivered] timeout:5];
}

- (void)testStatusReportsRequestedConfigurationAndBypassedFrame {
    XCTestExpectation *statusReceived = [self expectationWithDescription:@"status"];
    XCTestExpectation *delivered = [self expectationWithDescription:@"original"];
    RTCVideoUpscalingConfiguration *configuration =
        [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendOff scale:2
            linearColor:NO highPrecision:NO];
    [self.subject configure:configuration statusHandler:^(RTCVideoUpscalingStatus *status) {
        if (status.bypassedFrames != 1) return;
        XCTAssertGreaterThan(status.sequence, 0);
        XCTAssertEqual(status.configuration, configuration);
        XCTAssertEqual(status.effectiveBackend, RTCVideoUpscalingBackendOff);
        XCTAssertEqual(status.state, RTCVideoUpscalingStatePassthrough);
        XCTAssertEqual(status.inputWidth, 320);
        XCTAssertEqual(status.inputHeight, 180);
        XCTAssertEqual(status.outputWidth, 320);
        XCTAssertEqual(status.outputHeight, 180);
        XCTAssertEqual(status.enhancedFrames, 0);
        [statusReceived fulfill];
    }];
    [self.subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
        return NULL;
    } completion:^(CVPixelBufferRef output) { [delivered fulfill]; }];
    [self waitForExpectations:@[statusReceived, delivered] timeout:5];
}

- (void)testBusyOriginalPreventsLateProcessedFrameDelivery {
    XCTestExpectation *started = [self expectationWithDescription:@"started"];
    XCTestExpectation *delivered = [self expectationWithDescription:@"newer"];
    self.engine.started = ^{ [started fulfill]; };
    [self.subject configure:self.enabled];
    __block BOOL newerDelivered = NO;
    CVPixelBufferRef input = self.input;
    [self.subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
        XCTAssertFalse(NSThread.isMainThread);
        return CVPixelBufferRetain(input);
    } completion:^(CVPixelBufferRef output) {
        XCTAssertFalse(newerDelivered);
    }];
    [self waitForExpectations:@[started] timeout:5];
    RTCVideoUpscalingProcessor *subject = self.subject;
    HeldUpscalingEngine *engine = self.engine;
    [subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
        XCTFail(@"Busy frames must not convert input");
        return NULL;
    } completion:^(CVPixelBufferRef output) {
        XCTAssertTrue(output == nullptr);
        newerDelivered = YES;
        engine.finish(input, nil);
        engine.finish = nil;
        [subject configure:[[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendOff scale:2
            linearColor:NO highPrecision:NO]];
        [subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
            return NULL;
        } completion:^(CVPixelBufferRef finalOutput) {
            [delivered fulfill];
        }];
    }];
    [self waitForExpectations:@[delivered] timeout:5];
}

- (void)testDeadlineDeliversOriginalWhileBackendIsStillBusy {
    XCTestExpectation *started = [self expectationWithDescription:@"started"];
    XCTestExpectation *delivered = [self expectationWithDescription:@"deadline"];
    self.engine.started = ^{ [started fulfill]; };
    [self.subject configure:self.enabled];
    CVPixelBufferRef input = self.input;
    [self.subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
        return CVPixelBufferRetain(input);
    } completion:^(CVPixelBufferRef output) {
        XCTAssertTrue(output == nullptr);
        [delivered fulfill];
    }];
    [self waitForExpectations:@[started, delivered] timeout:5];
    if (self.engine.finish) self.engine.finish(input, nil);
    self.engine.finish = nil;
}
- (void)testBlockedStatusObserverDoesNotQueueIncomingFrames {
    XCTestExpectation *entered = [self expectationWithDescription:@"observer"];
    XCTestExpectation *delivered = [self expectationWithDescription:@"burst"];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    __block BOOL first = YES;
    [self.subject configure:[[RTCVideoUpscalingConfiguration alloc]
        initWithBackend:RTCVideoUpscalingBackendOff scale:2
        linearColor:NO highPrecision:NO]
        statusHandler:^(RTCVideoUpscalingStatus *status) {
            if (!first) return;
            first = NO;
            [entered fulfill];
            dispatch_semaphore_wait(release,
                dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }];
    [self waitForExpectations:@[entered] timeout:2];
    __block NSUInteger count = 0;
    for (NSUInteger index = 0; index < 100; ++index) {
        [self.subject submitWithWidth:320 height:180 provider:^CVPixelBufferRef {
            XCTFail(@"Off must not retain or convert waiting input");
            return NULL;
        } completion:^(CVPixelBufferRef output) {
            if (++count == 100) [delivered fulfill];
        }];
    }
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[delivered] timeout:1];
    dispatch_semaphore_signal(release);
    XCTAssertEqual(result, XCTWaiterResultCompleted);
}

@end
