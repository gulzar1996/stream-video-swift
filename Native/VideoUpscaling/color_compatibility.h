#ifndef STREAM_VIDEO_COLOR_COMPATIBILITY_H_
#define STREAM_VIDEO_COLOR_COMPATIBILITY_H_

#include "api/video/color_space.h"

namespace stream_video {

// Only descriptions with an exact Core Video mapping may be converted.
inline bool SupportsColorSpace(const webrtc::ColorSpace& color) {
  using Color = webrtc::ColorSpace;
  if (color.hdr_metadata() || color.range() == Color::RangeID::kDerived) {
    return false;
  }
  switch (color.primaries()) {
    case Color::PrimaryID::kUnspecified:
    case Color::PrimaryID::kBT709:
    case Color::PrimaryID::kSMPTE170M:
    case Color::PrimaryID::kBT2020:
    case Color::PrimaryID::kSMPTEST432:
      break;
    default:
      return false;
  }
  switch (color.transfer()) {
    case Color::TransferID::kUnspecified:
    case Color::TransferID::kBT709:
    case Color::TransferID::kSMPTE170M:
    case Color::TransferID::kIEC61966_2_1:
    case Color::TransferID::kLINEAR:
      break;
    default:
      return false;
  }
  switch (color.matrix()) {
    case Color::MatrixID::kUnspecified:
    case Color::MatrixID::kBT709:
    case Color::MatrixID::kBT470BG:
    case Color::MatrixID::kSMPTE170M:
    case Color::MatrixID::kBT2020_NCL:
      return true;
    default:
      return false;
  }
}

}  // namespace stream_video
#endif
