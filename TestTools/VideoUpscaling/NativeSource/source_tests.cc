#include "api/make_ref_counted.h"
#include "api/video/i420_buffer.h"
#include "pc/video_rtp_track_source.h"

namespace {
class Probe : public webrtc::VideoSinkInterface<webrtc::VideoFrame> {
 public:
  void OnFrame(const webrtc::VideoFrame&) override { ++frames; }
  int frames = 0;
};
}

extern "C" int FramesAfterChannelDetach() {
  auto source = webrtc::make_ref_counted<webrtc::VideoRtpTrackSource>(nullptr);
  Probe probe;
  source->AddOrUpdateSink(&probe, webrtc::VideoSinkWants());
  auto frame = webrtc::VideoFrame::Builder()
      .set_video_frame_buffer(webrtc::I420Buffer::Create(16, 16))
      .build();
  source->OnFrame(frame);
  source->ClearCallback();
  source->OnFrame(frame);
  source->RemoveSink(&probe);
  return probe.frames;
}

#include "sdk/objc/components/video_upscaling/color_compatibility.h"

extern "C" bool AcceptsUnsupportedColorMatrix() {
  using Color = webrtc::ColorSpace;
  Color color(Color::PrimaryID::kBT2020, Color::TransferID::kBT709,
              Color::MatrixID::kBT2020_CL, Color::RangeID::kLimited);
  return stream_video::SupportsColorSpace(color);
}

extern "C" bool AcceptsHDRTransfer() {
  using Color = webrtc::ColorSpace;
  Color color(Color::PrimaryID::kBT2020, Color::TransferID::kSMPTEST2084,
              Color::MatrixID::kBT2020_NCL, Color::RangeID::kLimited);
  return stream_video::SupportsColorSpace(color);
}
