#ifndef STREAM_VIDEO_UPSCALING_FRAME_GATE_H_
#define STREAM_VIDEO_UPSCALING_FRAME_GATE_H_

#include <cstdint>

namespace stream_video {

// The owner serializes state transitions.
class FrameGate {
 public:
  enum class Action { kProcess, kOriginal, kEnhanced, kDrop };
  struct Ticket {
    uint64_t sequence = 0;
    uint64_t generation = 0;
    double deadline_ms = 0;
  };
  struct Submission {
    Ticket ticket;
    Action action;
  };

  Submission Submit(bool enabled, double now_ms) {
    Ticket ticket{++sequence_, generation_, now_ms + 33};
    if (stopped_) return {ticket, Action::kDrop};
    if (!enabled || in_flight_) {
      delivered_ = ticket.sequence;
      return {ticket, Action::kOriginal};
    }
    in_flight_ = ticket.sequence;
    return {ticket, Action::kProcess};
  }

  Action Complete(Ticket ticket, double now_ms, bool succeeded) {
    if (in_flight_ != ticket.sequence) return Action::kDrop;
    in_flight_ = 0;
    if (!IsCurrent(ticket)) return Action::kDrop;
    delivered_ = ticket.sequence;
    return succeeded && now_ms < ticket.deadline_ms ? Action::kEnhanced
                                                   : Action::kOriginal;
  }

  Action Timeout(Ticket ticket) {
    if (in_flight_ != ticket.sequence || !IsCurrent(ticket)) {
      return Action::kDrop;
    }
    delivered_ = ticket.sequence;
    return Action::kOriginal;
  }

  void Reconfigure() { ++generation_; }
  void Stop() {
    stopped_ = true;
    Reconfigure();
  }

 private:
  bool IsCurrent(Ticket ticket) const {
    return !stopped_ && ticket.generation == generation_ &&
           ticket.sequence > delivered_;
  }

  uint64_t sequence_ = 0;
  uint64_t generation_ = 0;
  uint64_t delivered_ = 0;
  uint64_t in_flight_ = 0;
  bool stopped_ = false;
};

}  // namespace stream_video

#endif
