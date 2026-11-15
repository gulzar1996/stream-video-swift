#import "RTCVideoUpscaling.h"
#include "api/rtp_receiver_interface.h"

namespace webrtc {
void ConfigureReceivedVideoUpscaling(
    scoped_refptr<RtpReceiverInterface> receiver,
    RTCVideoUpscalingConfiguration *configuration,
    void (^status_handler)(RTCVideoUpscalingStatus *));
}
