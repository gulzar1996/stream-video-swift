#import "receiver_bridge.h"
#import "upscaling_processor.h"
#include "color_compatibility.h"
#import "sdk/objc/components/video_frame_buffer/RTCCVPixelBuffer.h"
#include "api/make_ref_counted.h"
#include "sdk/objc/native/src/objc_frame_buffer.h"
#include "third_party/libyuv/include/libyuv/convert_from.h"
#include "third_party/libyuv/include/libyuv/planar_functions.h"

#include <vector>

namespace webrtc {
namespace {

class ObjCReceivedVideoProcessor : public ReceivedVideoFrameProcessor {
 public:
  ObjCReceivedVideoProcessor()
      : processor_([[RTCVideoUpscalingProcessor alloc]
            initWithEngine:[[RTCVideoUpscalingEngine alloc] init]]) {}

  ~ObjCReceivedVideoProcessor() override {
    [processor_ stop];
    if (pool_) CVPixelBufferPoolRelease(pool_);
  }

  void Configure(RTCVideoUpscalingConfiguration *configuration,
                 void (^handler)(RTCVideoUpscalingStatus *)) {
    [processor_ configure:configuration statusHandler:handler];
  }

  void Stop() override { [processor_ stop]; }

  void Process(const VideoFrame& frame,
               std::function<void(const VideoFrame&)> deliver) override {
    auto self = scoped_refptr<ObjCReceivedVideoProcessor>(this);
    VideoFrame input_frame(frame);
    [processor_ submitWithWidth:frame.width() height:frame.height()
        provider:^CVPixelBufferRef {
          return self->CopyInput(input_frame);
        } completion:^(CVPixelBufferRef output) {
          VideoFrame result(input_frame);
          if (output) {
            result.set_video_frame_buffer(make_ref_counted<ObjCFrameBuffer>(
                [[RTCCVPixelBuffer alloc] initWithPixelBuffer:output]));
            result.clear_update_rect();
            if (auto color = result.color_space()) {
              color->set_range_from_uint8(
                  static_cast<uint8_t>(ColorSpace::RangeID::kLimited));
              result.set_color_space(color);
            }
          }
          deliver(result);
        }];
  }

 private:
  CVPixelBufferRef Allocate(int width, int height, OSType format) {
    if (!pool_ || width != width_ || height != height_ || format != format_) {
      if (pool_) CVPixelBufferPoolRelease(pool_);
      pool_ = nullptr;
      width_ = width;
      height_ = height;
      format_ = format;
      NSDictionary *attributes = @{
          (id)kCVPixelBufferWidthKey: @(width),
          (id)kCVPixelBufferHeightKey: @(height),
          (id)kCVPixelBufferPixelFormatTypeKey: @(format),
          (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
          (id)kCVPixelBufferMetalCompatibilityKey: @YES
      };
      if (CVPixelBufferPoolCreate(NULL, NULL,
              (__bridge CFDictionaryRef)attributes, &pool_) != kCVReturnSuccess) {
        return nullptr;
      }
    }
    CVPixelBufferRef result = nullptr;
    NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @3};
    CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        NULL, pool_, (__bridge CFDictionaryRef)limit, &result);
    return result;
  }

  CVPixelBufferRef CopyInput(const VideoFrame& frame) {
    auto buffer = frame.video_frame_buffer();
    if (frame.color_space() &&
        !stream_video::SupportsColorSpace(*frame.color_space())) return nullptr;
    if (buffer->type() == VideoFrameBuffer::Type::kNative) {
      id<RTCVideoFrameBuffer> wrapped = ToObjCVideoFrameBuffer(buffer);
      if (![wrapped isKindOfClass:RTCCVPixelBuffer.class]) return nullptr;
      RTCCVPixelBuffer *native = (RTCCVPixelBuffer *)wrapped;
      CVPixelBufferRef pixels = native.pixelBuffer;
      if (!native.requiresCropping &&
          ![native requiresScalingToWidth:frame.width() height:frame.height()]) {
        return CVPixelBufferRetain(pixels);
      }
      OSType format = CVPixelBufferGetPixelFormatType(pixels);
      if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
          format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
          format != kCVPixelFormatType_32BGRA) return nullptr;
      CVPixelBufferRef result = Allocate(frame.width(), frame.height(), format);
      if (!result) return nullptr;
      temporary_.resize([native bufferSizeForCroppingAndScalingToWidth:frame.width()
          height:frame.height()]);
      [native cropAndScaleTo:result withTempBuffer:temporary_.data()];
      CVBufferPropagateAttachments(pixels, result);
      CVBufferRemoveAttachment(result, kCVImageBufferCleanApertureKey);
      return result;
    }
    if (buffer->type() != VideoFrameBuffer::Type::kI420 &&
        buffer->type() != VideoFrameBuffer::Type::kNV12) return nullptr;
    bool full_range = !frame.color_space() ||
        frame.color_space()->range() != ColorSpace::RangeID::kLimited;
    CVPixelBufferRef result = Allocate(frame.width(), frame.height(), full_range
        ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (!result) return nullptr;
    if (CVPixelBufferLockBaseAddress(result, 0) != kCVReturnSuccess) {
      CVPixelBufferRelease(result);
      return nullptr;
    }
    auto y = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(result, 0));
    auto uv = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(result, 1));
    int stride_y = CVPixelBufferGetBytesPerRowOfPlane(result, 0);
    int stride_uv = CVPixelBufferGetBytesPerRowOfPlane(result, 1);
    int conversion;
    if (buffer->type() == VideoFrameBuffer::Type::kI420) {
      const auto* source = buffer->GetI420();
      conversion = libyuv::I420ToNV12(source->DataY(), source->StrideY(),
          source->DataU(), source->StrideU(), source->DataV(), source->StrideV(),
          y, stride_y, uv, stride_uv, frame.width(), frame.height());
    } else {
      const auto* source = buffer->GetNV12();
      conversion = libyuv::NV12Copy(source->DataY(), source->StrideY(),
          source->DataUV(), source->StrideUV(), y, stride_y, uv, stride_uv,
          frame.width(), frame.height());
    }
    CVPixelBufferUnlockBaseAddress(result, 0);
    if (conversion != 0) {
      CVPixelBufferRelease(result);
      return nullptr;
    }
    AttachColor(result, frame.color_space());
    return result;
  }

  void AttachColor(CVPixelBufferRef buffer,
                   const std::optional<ColorSpace>& color) {
    CFStringRef primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
    CFStringRef transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
    CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    if (color) {
      if (color->primaries() == ColorSpace::PrimaryID::kBT2020) {
        primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
      } else if (color->primaries() == ColorSpace::PrimaryID::kSMPTEST432) {
        primaries = kCVImageBufferColorPrimaries_P3_D65;
      } else if (color->primaries() == ColorSpace::PrimaryID::kSMPTE170M) {
        primaries = kCVImageBufferColorPrimaries_SMPTE_C;
      }
      if (color->transfer() == ColorSpace::TransferID::kIEC61966_2_1) {
        transfer = kCVImageBufferTransferFunction_sRGB;
      } else if (color->transfer() == ColorSpace::TransferID::kLINEAR) {
        transfer = kCVImageBufferTransferFunction_Linear;
      }
      if (color->matrix() == ColorSpace::MatrixID::kBT709) {
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      } else if (color->matrix() == ColorSpace::MatrixID::kBT2020_NCL) {
        matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
      }
    }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix,
                          kCVAttachmentMode_ShouldPropagate);
  }

  RTCVideoUpscalingProcessor *processor_;
  CVPixelBufferPoolRef pool_ = nullptr;
  int width_ = 0;
  int height_ = 0;
  OSType format_ = 0;
  std::vector<uint8_t> temporary_;
};

}  // namespace

void ConfigureReceivedVideoUpscaling(
    scoped_refptr<RtpReceiverInterface> receiver,
    RTCVideoUpscalingConfiguration *configuration,
    void (^status_handler)(RTCVideoUpscalingStatus *)) {
  receiver->UpdateReceivedVideoProcessor(
      [configuration, status_handler](
          scoped_refptr<ReceivedVideoFrameProcessor> existing) {
        auto processor = existing
            ? scoped_refptr<ObjCReceivedVideoProcessor>(
                  static_cast<ObjCReceivedVideoProcessor*>(existing.get()))
            : make_ref_counted<ObjCReceivedVideoProcessor>();
        processor->Configure(configuration, status_handler);
        return processor;
      });
}

}  // namespace webrtc
