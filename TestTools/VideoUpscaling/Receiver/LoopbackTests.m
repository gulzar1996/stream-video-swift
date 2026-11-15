#import <XCTest/XCTest.h>
#import <StreamWebRTC/StreamWebRTC.h>
#import <mach/mach.h>

@interface UpscalingFrameSample : NSObject
@property(nonatomic) int width;
@property(nonatomic) int height;
@property(nonatomic) RTCVideoRotation rotation;
@property(nonatomic) int64_t timeStampNs;
@property(nonatomic) int contrast;
@end
@implementation UpscalingFrameSample
@end

static uint64_t PhysicalFootprint(void) {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count)
        == KERN_SUCCESS ? info.phys_footprint : 0;
}

@interface UpscalingFrameProbe : NSObject <RTCVideoRenderer>
@property(nonatomic, strong) NSMutableArray<UpscalingFrameSample *> *frames;
@property(nonatomic, strong) XCTestExpectation *received;
@property(nonatomic, copy) void (^onFirstFrame)(void);
@property(nonatomic, copy) void (^onFrame)(NSUInteger);
@property(nonatomic) NSUInteger limit;
@end

@implementation UpscalingFrameProbe
- (instancetype)init {
    if ((self = [super init])) {
        _frames = [NSMutableArray array];
        _limit = 60;
    }
    return self;
}
- (void)setSize:(CGSize)size {}
- (void)renderFrame:(RTCVideoFrame *)frame {
    @synchronized (self) {
        if (!frame || self.frames.count >= self.limit) return;
        UpscalingFrameSample *sample = [[UpscalingFrameSample alloc] init];
        sample.width = frame.width;
        sample.height = frame.height;
        sample.rotation = frame.rotation;
        sample.timeStampNs = frame.timeStampNs;
        id<RTCI420Buffer> pixels = [frame.buffer toI420];
        sample.contrast = pixels.dataY[3 * frame.width / 4]
            - pixels.dataY[frame.width / 4];
        [self.frames addObject:sample];
        if (self.onFrame) self.onFrame(self.frames.count);
        if (self.frames.count == 1 && self.onFirstFrame) self.onFirstFrame();
        if (self.frames.count == self.limit) [self.received fulfill];
    }
}
@end

@interface LoopbackTests : XCTestCase <RTCPeerConnectionDelegate>
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) RTCPeerConnection *sender;
@property(nonatomic, strong) RTCPeerConnection *subscriber;
@property(nonatomic, strong) RTCRtpReceiver *receiver;
@property(nonatomic, strong) RTCVideoTrack *remoteTrack;
@property(nonatomic, strong) RTCVideoSource *source;
@property(nonatomic, strong) RTCVideoCapturer *capturer;
@property(nonatomic, strong) NSMutableArray<RTCIceCandidate *> *toSender;
@property(nonatomic, strong) NSMutableArray<RTCIceCandidate *> *toSubscriber;
@property(nonatomic, strong) UpscalingFrameProbe *first;
@property(nonatomic, strong) UpscalingFrameProbe *second;
@property(nonatomic, strong) XCTestExpectation *receiverCreated;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
@property(nonatomic) int inputWidth;
@property(nonatomic) int inputHeight;
@end

@implementation LoopbackTests
- (void)setUp {
    [super setUp];
    self.inputWidth = 320;
    self.inputHeight = 180;
    self.toSender = [NSMutableArray array];
    self.toSubscriber = [NSMutableArray array];
    self.factory = [[RTCPeerConnectionFactory alloc]
        initWithEncoderFactory:[[RTCDefaultVideoEncoderFactory alloc] init]
        decoderFactory:[[RTCDefaultVideoDecoderFactory alloc] init]];
    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
        initWithMandatoryConstraints:nil optionalConstraints:nil];
    self.sender = [self.factory peerConnectionWithConfiguration:configuration
        constraints:constraints delegate:self];
    self.subscriber = [self.factory peerConnectionWithConfiguration:configuration
        constraints:constraints delegate:self];
    self.source = [self.factory videoSource];
    [self.source adaptOutputFormatToWidth:320 height:180 fps:30];
    self.capturer = [[RTCVideoCapturer alloc] initWithDelegate:self.source];
    self.captureQueue = dispatch_queue_create("io.getstream.tests.capture", NULL);
    self.first = [[UpscalingFrameProbe alloc] init];
    self.second = [[UpscalingFrameProbe alloc] init];
    self.first.received = [self expectationWithDescription:@"first renderer"];
    self.second.received = [self expectationWithDescription:@"second renderer"];
    self.receiverCreated = [self expectationWithDescription:@"receiver"];
}

- (void)tearDown {
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        dispatch_sync(self.captureQueue, ^{});
        self.timer = nil;
    }
    [self.remoteTrack removeRenderer:self.first];
    [self.remoteTrack removeRenderer:self.second];
    self.sender.delegate = nil;
    self.subscriber.delegate = nil;
    [self.sender close];
    [self.subscriber close];
    self.receiver = nil;
    self.remoteTrack = nil;
    self.sender = nil;
    self.subscriber = nil;
    self.capturer = nil;
    self.source = nil;
    self.factory = nil;
    self.first = nil;
    self.second = nil;
    self.toSender = nil;
    self.toSubscriber = nil;
    [super tearDown];
}

- (void)applyDescription:(RTCSessionDescription *)description
                      to:(RTCPeerConnection *)peer
                   local:(BOOL)local {
    XCTestExpectation *applied = [self expectationWithDescription:@"description"];
    void (^completion)(NSError *) = ^(NSError *error) {
        XCTAssertNil(error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!local) [self flushCandidatesFor:peer];
            [applied fulfill];
        });
    };
    if (local) [peer setLocalDescription:description completionHandler:completion];
    else [peer setRemoteDescription:description completionHandler:completion];
    [self waitForExpectations:@[applied] timeout:10];
}

- (RTCSessionDescription *)descriptionFor:(RTCPeerConnection *)peer offer:(BOOL)offer {
    XCTestExpectation *created = [self expectationWithDescription:@"SDP"];
    __block RTCSessionDescription *result;
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
        initWithMandatoryConstraints:nil optionalConstraints:nil];
    void (^completion)(RTCSessionDescription *, NSError *) =
        ^(RTCSessionDescription *description, NSError *error) {
            XCTAssertNil(error);
            result = description;
            [created fulfill];
        };
    if (offer) [peer offerForConstraints:constraints completionHandler:completion];
    else [peer answerForConstraints:constraints completionHandler:completion];
    [self waitForExpectations:@[created] timeout:10];
    return result;
}

- (void)connectWithCodec:(NSString *)codec {
    [self.source adaptOutputFormatToWidth:self.inputWidth height:self.inputHeight fps:30];
    RTCVideoTrack *track = [self.factory videoTrackWithSource:self.source trackId:@"video"];
    RTCRtpTransceiverInit *options = [[RTCRtpTransceiverInit alloc] init];
    options.direction = RTCRtpTransceiverDirectionSendOnly;
    RTCRtpTransceiver *transceiver = [self.sender addTransceiverWithTrack:track init:options];
    NSArray *codecs = [[self.factory rtpSenderCapabilitiesForKind:kRTCMediaStreamTrackKindVideo].codecs
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(RTCRtpCodecCapability *candidate, NSDictionary *bindings) {
                return [candidate.name caseInsensitiveCompare:codec] == NSOrderedSame;
            }]];
    XCTSkipIf(codecs.count == 0, @"Codec %@ is not available", codec);
    NSError *error = nil;
    XCTAssertTrue([transceiver setCodecPreferences:codecs error:&error]);
    XCTAssertNil(error);
    RTCSessionDescription *offer = [self descriptionFor:self.sender offer:YES];
    [self applyDescription:offer to:self.sender local:YES];
    [self applyDescription:offer to:self.subscriber local:NO];
    RTCSessionDescription *answer = [self descriptionFor:self.subscriber offer:NO];
    [self applyDescription:answer to:self.subscriber local:YES];
    [self applyDescription:answer to:self.sender local:NO];
    if (self.inputWidth >= 1920) {
        RTCRtpParameters *parameters = transceiver.sender.parameters;
        parameters.degradationPreference =
            @(RTCDegradationPreferenceMaintainFramerateAndResolution);
        for (RTCRtpEncodingParameters *encoding in parameters.encodings) {
            encoding.minBitrateBps = @5000000;
            encoding.maxBitrateBps = @10000000;
        }
        transceiver.sender.parameters = parameters;
        XCTAssertTrue([self.sender setBweMinBitrateBps:@5000000
            currentBitrateBps:@5000000 maxBitrateBps:@10000000]);
    }
    [self waitForExpectations:@[self.receiverCreated] timeout:10];
}

- (void)startFrames {
    int width = self.inputWidth;
    int height = self.inputHeight;
    RTCVideoSource *source = self.source;
    RTCVideoCapturer *capturer = self.capturer;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.captureQueue);
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, 0);
    __block int frameIndex = 0;
    dispatch_source_set_event_handler(self.timer, ^{
        CVPixelBufferRef buffer = NULL;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        CVPixelBufferCreate(NULL, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attributes, &buffer);
        CVPixelBufferLockBaseAddress(buffer, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        for (size_t y = 0; y < height; ++y) {
            for (size_t x = 0; x < width; ++x) {
                luma[y * stride + x] = x < width / 2 ? 64 + frameIndex % 8 : 180;
            }
        }
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2));
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        RTCVideoFrame *frame = [[RTCVideoFrame alloc]
            initWithBuffer:[[RTCCVPixelBuffer alloc] initWithPixelBuffer:buffer]
            rotation:RTCVideoRotation_90
            timeStampNs:(int64_t)(NSProcessInfo.processInfo.systemUptime * 1e9)];
        [source capturer:capturer didCaptureVideoFrame:frame];
        CVPixelBufferRelease(buffer);
        ++frameIndex;
    });
    dispatch_resume(self.timer);
}

- (void)verifyCodec:(NSString *)codec backend:(RTCVideoUpscalingBackend)backend {
    [self connectWithCodec:codec];
    NSMutableArray<NSNumber *> *latencies = [NSMutableArray array];
    [self.receiver setVideoUpscalingConfiguration:
        [[RTCVideoUpscalingConfiguration alloc] initWithBackend:backend
            scale:2 linearColor:NO highPrecision:NO]
        statusHandler:^(RTCVideoUpscalingStatus *status) {
            if (status.state == RTCVideoUpscalingStateActive) {
                @synchronized (latencies) {
                    [latencies addObject:@(status.processingMilliseconds)];
                }
            }
        }];
    uint64_t memoryBefore = PhysicalFootprint();
    NSProcessInfoThermalState thermalBefore = NSProcessInfo.processInfo.thermalState;
    [self startFrames];
    [self waitForExpectations:@[self.first.received, self.second.received] timeout:15];
    @synchronized (self.first) {
        @synchronized (self.second) {
            XCTAssertEqual(self.first.frames.count, 60);
            XCTAssertEqual(self.second.frames.count, 60);
            NSUInteger enhanced = 0;
            for (NSUInteger index = 0; index < MIN(self.first.frames.count, self.second.frames.count); ++index) {
                UpscalingFrameSample *first = self.first.frames[index];
                UpscalingFrameSample *second = self.second.frames[index];
                XCTAssertEqual(first.timeStampNs, second.timeStampNs);
                XCTAssertEqual(first.width, second.width);
                XCTAssertEqual(first.height, second.height);
                XCTAssertEqual(first.rotation, RTCVideoRotation_90);
                XCTAssertGreaterThan(first.contrast, 70);
                if (index > 0) {
                    XCTAssertGreaterThan(first.timeStampNs, self.first.frames[index - 1].timeStampNs);
                }
                if (first.width == self.inputWidth * 2 && first.height == self.inputHeight * 2) ++enhanced;
                else {
                    XCTAssertEqual(first.width, self.inputWidth);
                    XCTAssertEqual(first.height, self.inputHeight);
                }
            }
            if (backend == RTCVideoUpscalingBackendOff) XCTAssertEqual(enhanced, 0);
            else XCTAssertGreaterThan(enhanced, 30);
            NSArray<NSNumber *> *samples;
            @synchronized (latencies) { samples = [latencies copy]; }
            if (backend != RTCVideoUpscalingBackendOff) XCTAssertGreaterThan(samples.count, 0);
            double mean = samples.count ? [[samples valueForKeyPath:@"@avg.self"] doubleValue] : 0;
            double maximum = [[samples valueForKeyPath:@"@max.self"] doubleValue];
            XCTAttachment *metrics = [XCTAttachment attachmentWithString:
                [NSString stringWithFormat:
                    @"codec=%@ backend=%ld frames=%lu enhanced=%lu footprintBefore=%llu footprintAfter=%llu thermalBefore=%ld thermalAfter=%ld processingMeanMs=%.3f processingMaxMs=%.3f processingSamples=%lu",
                    codec, (long)backend, (unsigned long)self.first.frames.count,
                    (unsigned long)enhanced, memoryBefore, PhysicalFootprint(),
                    (long)thermalBefore, (long)NSProcessInfo.processInfo.thermalState,
                    mean, maximum, (unsigned long)samples.count]];
            metrics.name = @"Loopback runtime metrics";
            metrics.lifetime = XCTAttachmentLifetimeKeepAlways;
            [self addAttachment:metrics];
        }
    }
}

- (void)testRendererCanConfigureReceiverWithoutBlockingWorker {
    __weak LoopbackTests *weakSelf = self;
    self.first.onFirstFrame = ^{
        dispatch_semaphore_t configured = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [weakSelf.receiver setVideoUpscalingConfiguration:
                [[RTCVideoUpscalingConfiguration alloc]
                    initWithBackend:RTCVideoUpscalingBackendOff scale:2
                    linearColor:NO highPrecision:NO] statusHandler:nil];
            dispatch_semaphore_signal(configured);
        });
        XCTAssertEqual(dispatch_semaphore_wait(configured,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    };
    [self verifyCodec:@"VP8" backend:RTCVideoUpscalingBackendOff];
}

- (void)testH264OffPreservesDecodedFrames {
    [self verifyCodec:@"H264" backend:RTCVideoUpscalingBackendOff];
}
- (void)testH264MetalFXChangesRendererFrames {
    [self verifyCodec:@"H264" backend:RTCVideoUpscalingBackendMetalFX];
}
- (void)testH264MetalFXProduces4KRendererFrames {
    self.inputWidth = 1920;
    self.inputHeight = 1080;
    [self verifyCodec:@"H264" backend:RTCVideoUpscalingBackendMetalFX];
}
- (void)testVP8MetalFXProcessesSoftwareDecodedFrames {
    [self verifyCodec:@"VP8" backend:RTCVideoUpscalingBackendMetalFX];
}

- (void)testH264VideoToolboxChangesRendererFrames {
    self.inputWidth = 640;
    self.inputHeight = 360;
    [self verifyCodec:@"H264" backend:RTCVideoUpscalingBackendVideoToolbox];
}
- (void)testVP9MetalFXChangesRendererFrames {
    [self verifyCodec:@"VP9" backend:RTCVideoUpscalingBackendMetalFX];
}
- (void)testAV1MetalFXChangesRendererFrames {
    [self verifyCodec:@"AV1" backend:RTCVideoUpscalingBackendMetalFX];
}
- (void)testH265MetalFXChangesRendererFrames {
    [self verifyCodec:@"H265" backend:RTCVideoUpscalingBackendMetalFX];
}

- (void)testLiveBackendChangesPreservePlayback {
    [self connectWithCodec:@"H264"];
    self.first.limit = 90;
    self.second.limit = 90;
    __weak LoopbackTests *weakSelf = self;
    self.first.onFrame = ^(NSUInteger count) {
        RTCVideoUpscalingBackend backend;
        if (count == 20) backend = RTCVideoUpscalingBackendMetalFX;
        else if (count == 40) backend = RTCVideoUpscalingBackendVideoToolbox;
        else if (count == 60) backend = RTCVideoUpscalingBackendOff;
        else return;
        [weakSelf.receiver setVideoUpscalingConfiguration:
            [[RTCVideoUpscalingConfiguration alloc] initWithBackend:backend
                scale:2 linearColor:NO highPrecision:NO] statusHandler:nil];
    };
    [self startFrames];
    [self waitForExpectations:@[self.first.received, self.second.received] timeout:15];
    @synchronized (self.first) {
        NSUInteger metalFrames = 0;
        for (NSUInteger index = 0; index < self.first.frames.count; ++index) {
            UpscalingFrameSample *frame = self.first.frames[index];
            if (index < 20 || index >= 62) XCTAssertEqual(frame.width, 320);
            if (index > 20 && index < 40 && frame.width == 640) ++metalFrames;
        }
        XCTAssertGreaterThan(metalFrames, 10);
    }
    XCTAssertEqual(self.subscriber.signalingState, RTCSignalingStateStable);
}

- (void)flushCandidatesFor:(RTCPeerConnection *)peer {
    NSMutableArray *pending = peer == self.sender ? self.toSender : self.toSubscriber;
    for (RTCIceCandidate *candidate in pending) {
        [peer addIceCandidate:candidate completionHandler:^(NSError *error) {
            XCTAssertNil(error);
        }];
    }
    [pending removeAllObjects];
}
- (void)peerConnection:(RTCPeerConnection *)peer didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (peer != self.sender && peer != self.subscriber) return;
        RTCPeerConnection *other = peer == self.sender ? self.subscriber : self.sender;
        NSMutableArray *pending = other == self.sender ? self.toSender : self.toSubscriber;
        [pending addObject:candidate];
        if (other.remoteDescription) [self flushCandidatesFor:other];
    });
}
- (void)peerConnection:(RTCPeerConnection *)peer didAddReceiver:(RTCRtpReceiver *)receiver streams:(NSArray<RTCMediaStream *> *)streams {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (peer != self.subscriber || ![receiver.track isKindOfClass:RTCVideoTrack.class]) return;
        self.receiver = receiver;
        self.remoteTrack = (RTCVideoTrack *)receiver.track;
        [self.remoteTrack addRenderer:self.first];
        [self.remoteTrack addRenderer:self.second];
        [self.receiverCreated fulfill];
    });
}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeSignalingState:(RTCSignalingState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peer {}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceConnectionState:(RTCIceConnectionState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceGatheringState:(RTCIceGatheringState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
- (void)peerConnection:(RTCPeerConnection *)peer didOpenDataChannel:(RTCDataChannel *)channel {}
@end
