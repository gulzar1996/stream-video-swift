#import "upscaling_processor.h"
#include "frame_gate.h"
#include <mutex>

using stream_video::FrameGate;

@interface RTCUpscalingJob : NSObject {
@public
    FrameGate::Ticket ticket;
}
@property(nonatomic, copy) void (^completion)(CVPixelBufferRef);
@end

@implementation RTCUpscalingJob
@end

@interface RTCVideoUpscalingStatus ()
@property(nonatomic, readwrite) RTCVideoUpscalingConfiguration *configuration;
@property(nonatomic, readwrite) uint64_t sequence;
@property(nonatomic, readwrite) RTCVideoUpscalingBackend effectiveBackend;
@property(nonatomic, readwrite) RTCVideoUpscalingState state;
@property(nonatomic, readwrite) NSString *fallbackReason;
@property(nonatomic, readwrite) NSInteger inputWidth;
@property(nonatomic, readwrite) NSInteger inputHeight;
@property(nonatomic, readwrite) NSInteger outputWidth;
@property(nonatomic, readwrite) NSInteger outputHeight;
@property(nonatomic, readwrite) double processingMilliseconds;
@property(nonatomic, readwrite) uint64_t enhancedFrames;
@property(nonatomic, readwrite) uint64_t bypassedFrames;
@end

@implementation RTCVideoUpscalingStatus
@end

@implementation RTCVideoUpscalingProcessor {
    std::recursive_mutex _stateLock;
    std::recursive_mutex _deliveryLock;
    dispatch_queue_t _notifications;
    dispatch_queue_t _worker;
    FrameGate _gate;
    RTCVideoUpscalingEngine *_engine;
    RTCVideoUpscalingConfiguration *_configuration;
    RTCUpscalingJob *_job;
    void (^_statusHandler)(RTCVideoUpscalingStatus *);
    RTCVideoUpscalingStatus *_pendingStatus;
    BOOL _notificationScheduled;
    uint64_t _statusSequence;
    uint64_t _enhancedFrames;
    uint64_t _bypassedFrames;
    size_t _inputWidth;
    size_t _inputHeight;
    BOOL _preparing;
    BOOL _stopped;
}

- (instancetype)initWithEngine:(RTCVideoUpscalingEngine *)engine {
    if ((self = [super init])) {
        _engine = engine;
        _notifications = dispatch_queue_create("io.getstream.upscaling.status", NULL);
        _worker = dispatch_queue_create("io.getstream.upscaling.processing",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _configuration = [[RTCVideoUpscalingConfiguration alloc]
            initWithBackend:RTCVideoUpscalingBackendOff scale:2
            linearColor:NO highPrecision:NO];
    }
    return self;
}

- (void)configure:(RTCVideoUpscalingConfiguration *)configuration {
    [self configure:configuration statusHandler:nil];
}

- (void)configure:(RTCVideoUpscalingConfiguration *)configuration
    statusHandler:(void (^)(RTCVideoUpscalingStatus *))statusHandler {
    std::lock_guard<std::recursive_mutex> lock(_stateLock);
    if (_stopped) return;
    _gate.Reconfigure();
    _configuration = configuration;
    _job.completion = nil;
    _pendingStatus = nil;
    _statusHandler = [statusHandler copy];
    _preparing = configuration.backend != RTCVideoUpscalingBackendOff;
    [self publishState:_preparing ? RTCVideoUpscalingStatePreparing
                                 : RTCVideoUpscalingStatePassthrough
        reason:nil output:NULL elapsed:0];
}

- (void)publishState:(RTCVideoUpscalingState)state
              reason:(NSString *)reason
              output:(CVPixelBufferRef)output
             elapsed:(double)elapsed {
    if (!_statusHandler) return;
    RTCVideoUpscalingStatus *status = [[RTCVideoUpscalingStatus alloc] init];
    status.configuration = _configuration;
    status.sequence = ++_statusSequence;
    status.effectiveBackend = state == RTCVideoUpscalingStateActive
        ? _configuration.backend : RTCVideoUpscalingBackendOff;
    status.state = state;
    status.fallbackReason = reason;
    status.inputWidth = _inputWidth;
    status.inputHeight = _inputHeight;
    status.outputWidth = output ? CVPixelBufferGetWidth(output) : _inputWidth;
    status.outputHeight = output ? CVPixelBufferGetHeight(output) : _inputHeight;
    status.processingMilliseconds = elapsed;
    status.enhancedFrames = _enhancedFrames;
    status.bypassedFrames = _bypassedFrames;
    _pendingStatus = status;
    if (_notificationScheduled) return;
    _notificationScheduled = YES;
    dispatch_async(_notifications, ^{
        while (YES) {
            RTCVideoUpscalingStatus *next;
            void (^handler)(RTCVideoUpscalingStatus *);
            {
                std::lock_guard<std::recursive_mutex> lock(self->_stateLock);
                next = self->_pendingStatus;
                self->_pendingStatus = nil;
                handler = self->_statusHandler;
                if (!next || !handler) {
                    self->_notificationScheduled = NO;
                    return;
                }
            }
            handler(next);
        }
    });
}

- (void)submitWithWidth:(size_t)width
                height:(size_t)height
              provider:(CVPixelBufferRef (^)(void))provider
            completion:(void (^)(CVPixelBufferRef))completion {
    double arrival = NSProcessInfo.processInfo.systemUptime * 1000;
    // Renderer backpressure stays at admission, without retained frame blocks.
    std::lock_guard<std::recursive_mutex> delivery(_deliveryLock);
    RTCUpscalingJob *job;
    RTCVideoUpscalingConfiguration *configuration;
    RTCVideoUpscalingEngine *engine;
    {
        std::lock_guard<std::recursive_mutex> lock(_stateLock);
        if (_inputWidth != width || _inputHeight != height) {
            _gate.Reconfigure();
            _job.completion = nil;
            _preparing = YES;
        }
        _inputWidth = width;
        _inputHeight = height;
        auto submission = _gate.Submit(
            _configuration.backend != RTCVideoUpscalingBackendOff, arrival);
        if (submission.action == FrameGate::Action::kDrop) return;
        if (submission.action == FrameGate::Action::kOriginal) {
            ++_bypassedFrames;
            [self publishState:RTCVideoUpscalingStatePassthrough
                reason:_configuration.backend == RTCVideoUpscalingBackendOff
                    ? nil : @"busy" output:NULL elapsed:0];
        } else {
            job = [[RTCUpscalingJob alloc] init];
            job->ticket = submission.ticket;
            job.completion = completion;
            _job = job;
            configuration = _configuration;
            engine = _engine;
            if (_preparing) {
                [self publishState:RTCVideoUpscalingStatePreparing reason:nil
                    output:NULL elapsed:0];
            }
        }
    }
    if (!job) {
        completion(NULL);
        return;
    }
    double remaining = MAX(0, job->ticket.deadline_ms -
        NSProcessInfo.processInfo.systemUptime * 1000);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, remaining * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::lock_guard<std::recursive_mutex> timedDelivery(self->_deliveryLock);
            void (^callback)(CVPixelBufferRef);
            {
                std::lock_guard<std::recursive_mutex> lock(self->_stateLock);
                auto action = self->_gate.Timeout(job->ticket);
                if (action == FrameGate::Action::kOriginal && job.completion) {
                    callback = job.completion;
                    ++self->_bypassedFrames;
                    [self publishState:RTCVideoUpscalingStatePassthrough
                        reason:@"deadlineExceeded" output:NULL elapsed:33];
                }
                job.completion = nil;
            }
            if (callback) callback(NULL);
        });
    dispatch_async(_worker, ^{
        @autoreleasepool {
            CVPixelBufferRef input = provider();
            if (!input) {
                [self finishJob:job output:NULL reason:@"unsupportedFormat"];
                return;
            }
            [engine processPixelBuffer:input configuration:configuration
                completion:^(CVPixelBufferRef output, NSString *reason) {
                    [self finishJob:job output:output reason:reason];
                    CVPixelBufferRelease(input);
                }];
        }
    });
}

- (void)finishJob:(RTCUpscalingJob *)job
           output:(CVPixelBufferRef)output
           reason:(NSString *)reason {
    std::lock_guard<std::recursive_mutex> delivery(_deliveryLock);
    void (^callback)(CVPixelBufferRef);
    CVPixelBufferRef delivered = NULL;
    {
        std::lock_guard<std::recursive_mutex> lock(_stateLock);
        double now = NSProcessInfo.processInfo.systemUptime * 1000;
        auto action = _gate.Complete(job->ticket, now, reason == nil && output);
        if (job.completion) {
            double elapsed = now - (job->ticket.deadline_ms - 33);
            if (action == FrameGate::Action::kEnhanced) {
                callback = job.completion;
                delivered = output;
                ++_enhancedFrames;
                _preparing = NO;
                [self publishState:RTCVideoUpscalingStateActive reason:nil
                    output:output elapsed:elapsed];
            }
            if (action == FrameGate::Action::kOriginal) {
                callback = job.completion;
                ++_bypassedFrames;
                _preparing = NO;
                [self publishState:RTCVideoUpscalingStatePassthrough
                    reason:now >= job->ticket.deadline_ms ? @"deadlineExceeded" : reason
                    output:NULL elapsed:elapsed];
            }
        }
        job.completion = nil;
        if (_job == job) _job = nil;
    }
    if (callback) callback(delivered);
}

- (void)stop {
    std::lock_guard<std::recursive_mutex> lock(_stateLock);
    _stopped = YES;
    _gate.Stop();
    _job.completion = nil;
    _pendingStatus = nil;
    _statusHandler = nil;
    _engine = nil;
}
@end
