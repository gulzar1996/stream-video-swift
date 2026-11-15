//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
@testable import StreamVideo
import XCTest

@MainActor
final class CallVideoUpscaling_Tests: StreamVideoTestCase, @unchecked Sendable {
    func test_setAndReset_applyToCallOwner() async throws {
        let subject = streamVideo.call(callType: "default", callId: "upscaling")
        let track = VideoUpscalingTrack(participantSessionID: "remote")
        let enabled = VideoUpscalingConfiguration(backend: .metalFX)
        try await subject.setVideoUpscaling(enabled)
        let applied = await subject.callController.videoUpscaling.configuration(for: track)
        XCTAssertEqual(applied, enabled)
        await fulfilmentInMainActor { subject.state.videoUpscalingDefault == enabled }
        try await subject.setVideoUpscaling(.off, for: .track(track))
        await fulfilmentInMainActor { subject.state.videoUpscalingOverrides[track] == .off }
        await subject.resetVideoUpscaling(for: .track(track))
        await fulfilmentInMainActor { subject.state.videoUpscalingOverrides[track] == nil }
        await subject.resetVideoUpscaling()
        let reset = await subject.callController.videoUpscaling.configuration(for: track)
        XCTAssertEqual(reset, .off)
        subject.leave()
    }

    func test_statusPublication_doesNotRegressOnMainActor() async {
        let subject = streamVideo.call(callType: "default", callId: "status-order")
        defer { subject.leave() }
        let owner = subject.callController.videoUpscaling
        let track = VideoUpscalingTrack(participantSessionID: "remote")
        var observed: [UInt64] = []
        let observation = subject.state.$videoUpscalingStatuses.sink {
            if let count = $0[track]?.enhancedFrames { observed.append(count) }
        }
        defer { observation.cancel() }
        await Task.detached {
            for count in 1...2000 {
                owner.statuses.send([track: .init(
                    configuration: .off, effectiveBackend: .off, state: .passthrough,
                    fallbackReason: nil, inputWidth: 320, inputHeight: 180,
                    outputWidth: 320, outputHeight: 180, processingMilliseconds: 0,
                    enhancedFrames: UInt64(count), bypassedFrames: 0
                )])
                await Task.yield()
            }
        }.value
        await fulfilmentInMainActor { subject.state.videoUpscalingStatuses[track]?.enhancedFrames == 2000 }
        XCTAssertEqual(observed, observed.sorted())
    }

    func test_capabilities_forwardRuntimeSupport() async {
        let subject = streamVideo.call(callType: "default", callId: "capabilities")
        let capabilities = await subject.videoUpscalingCapabilities(for: .init(participantSessionID: "remote"))
        XCTAssertEqual(capabilities.backends.count, 3)
        subject.leave()
    }

    func test_statusUpdates_reachCallState() async {
        let subject = streamVideo.call(callType: "default", callId: "status")
        let track = VideoUpscalingTrack(participantSessionID: "remote")
        let status = VideoUpscalingStatus(
            configuration: .off, effectiveBackend: .off, state: .passthrough,
            fallbackReason: nil, inputWidth: 320, inputHeight: 180,
            outputWidth: 320, outputHeight: 180, processingMilliseconds: 0,
            enhancedFrames: 0, bypassedFrames: 1
        )
        subject.callController.videoUpscaling.statuses.send([track: status])
        await fulfilmentInMainActor { subject.state.videoUpscalingStatuses[track] == status }
        subject.leave()
        await fulfilmentInMainActor { subject.state.videoUpscalingStatuses.isEmpty }
    }
}
