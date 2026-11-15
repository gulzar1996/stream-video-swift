#import <XCTest/XCTest.h>

#include "frame_gate.h"

using stream_video::FrameGate;
using Action = FrameGate::Action;

@interface FrameGateTests : XCTestCase
@end

@implementation FrameGateTests

- (void)testOffDeliversOriginal {
    FrameGate subject;
    XCTAssertTrue(subject.Submit(false, 0).action == Action::kOriginal);
}

- (void)testSuccessfulProcessingDeliversOnce {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    XCTAssertTrue(first.action == Action::kProcess);
    XCTAssertTrue(subject.Complete(first.ticket, 32, true) == Action::kEnhanced);
    XCTAssertTrue(subject.Complete(first.ticket, 32, true) == Action::kDrop);
    XCTAssertTrue(subject.Timeout(first.ticket) == Action::kDrop);
}

- (void)testBusyFrameBypassesAndInvalidatesOlderResult {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    XCTAssertTrue(subject.Submit(true, 1).action == Action::kOriginal);
    XCTAssertTrue(subject.Complete(first.ticket, 2, true) == Action::kDrop);
    XCTAssertTrue(subject.Submit(true, 3).action == Action::kProcess);
}

- (void)testDeadlineDeliversOriginalAndRetainsBusySlot {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    XCTAssertEqual(first.ticket.deadline_ms, 33);
    XCTAssertTrue(subject.Timeout(first.ticket) == Action::kOriginal);
    XCTAssertTrue(subject.Submit(true, 34).action == Action::kOriginal);
    XCTAssertTrue(subject.Complete(first.ticket, 40, true) == Action::kDrop);
    XCTAssertTrue(subject.Submit(true, 41).action == Action::kProcess);
}

- (void)testCompletionAtDeadlineFallsBackEvenBeforeTimerRuns {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    XCTAssertTrue(subject.Complete(first.ticket, 33, true) == Action::kOriginal);
    XCTAssertTrue(subject.Timeout(first.ticket) == Action::kDrop);
}

- (void)testFailureDeliversOriginal {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    XCTAssertTrue(subject.Complete(first.ticket, 10, false) == Action::kOriginal);
}

- (void)testReconfigurationInvalidatesCompletionButKeepsBusySlot {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    subject.Reconfigure();
    XCTAssertTrue(subject.Timeout(first.ticket) == Action::kDrop);
    XCTAssertTrue(subject.Submit(true, 1).action == Action::kOriginal);
    XCTAssertTrue(subject.Complete(first.ticket, 2, true) == Action::kDrop);
    XCTAssertTrue(subject.Submit(true, 3).action == Action::kProcess);
}

- (void)testOldCompletionCannotReleaseNewOperation {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    subject.Complete(first.ticket, 1, true);
    auto second = subject.Submit(true, 2);
    XCTAssertTrue(subject.Complete(first.ticket, 3, true) == Action::kDrop);
    XCTAssertTrue(subject.Submit(true, 4).action == Action::kOriginal);
    XCTAssertTrue(subject.Complete(second.ticket, 5, true) == Action::kDrop);
}

- (void)testStopRejectsPendingAndFutureFrames {
    FrameGate subject;
    auto first = subject.Submit(true, 0);
    subject.Stop();
    XCTAssertTrue(subject.Timeout(first.ticket) == Action::kDrop);
    XCTAssertTrue(subject.Complete(first.ticket, 1, true) == Action::kDrop);
    XCTAssertTrue(subject.Submit(false, 2).action == Action::kDrop);
}

@end
