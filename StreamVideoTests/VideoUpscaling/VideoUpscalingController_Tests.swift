//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Combine
import Foundation
@testable import StreamVideo
import XCTest

final class VideoUpscalingController_Tests: XCTestCase, @unchecked Sendable {
    private var subject: VideoUpscalingController! = .init()
    private let camera = VideoUpscalingTrack(participantSessionID: "remote")
    private let screen = VideoUpscalingTrack(participantSessionID: "remote", source: .screenShare)
    private let enabled = VideoUpscalingConfiguration(backend: .metalFX)

    override func tearDown() async throws {
        await subject.disconnect(reconnecting: false)
        subject = nil
        try await super.tearDown()
    }

    func test_defaultAndOverride_resetRestoresInheritance() async throws {
        try await subject.set(enabled, for: .all)
        try await subject.set(.off, for: .track(camera))
        let cameraValue = await subject.configuration(for: camera)
        let screenValue = await subject.configuration(for: screen)
        XCTAssertEqual(cameraValue, .off)
        XCTAssertEqual(screenValue, enabled)
        await subject.reset(for: .track(camera))
        let inherited = await subject.configuration(for: camera)
        XCTAssertEqual(inherited, enabled)
    }

    func test_configurationBeforeArrival_appliesToReplacementAndReconnect() async throws {
        try await subject.set(enabled, for: .track(camera))
        let first = Receiver()
        let replacement = Receiver()
        await subject.attach(first, for: camera)
        await subject.attach(replacement, for: camera)
        XCTAssertEqual(first.configurations, [enabled])
        XCTAssertEqual(first.detachCount, 1)
        XCTAssertEqual(replacement.configurations, [enabled])
        await subject.disconnect(reconnecting: true)
        XCTAssertEqual(replacement.detachCount, 1)
        let reconnected = Receiver()
        await subject.attach(reconnected, for: camera)
        XCTAssertEqual(reconnected.configurations, [enabled])
    }

    func test_participantDeparture_removesOnlyDepartedSessionOverride() async throws {
        let other = VideoUpscalingTrack(participantSessionID: "other")
        try await subject.set(enabled, for: .track(camera))
        try await subject.set(enabled, for: .track(other))
        await subject.participantLeft("remote")
        let departed = await subject.configuration(for: camera)
        let remaining = await subject.configuration(for: other)
        XCTAssertEqual(departed, .off)
        XCTAssertEqual(remaining, enabled)
    }

    func test_cameraAndScreen_liveUpdatesRemainIndependent() async throws {
        let cameraReceiver = Receiver()
        let screenReceiver = Receiver()
        await subject.attach(cameraReceiver, for: camera)
        await subject.attach(screenReceiver, for: screen)
        try await subject.set(enabled, for: .track(screen))
        XCTAssertEqual(cameraReceiver.configurations, [.off])
        XCTAssertEqual(screenReceiver.configurations, [.off, enabled])
    }

    func test_invalidConfiguration_preservesPreviousSetting() async throws {
        try await subject.set(enabled, for: .all)
        for scale in [Double.nan, .infinity, 0, 1, 1.7] {
            do {
                try await subject.set(.init(backend: .metalFX, scale: scale), for: .all)
                XCTFail("Invalid scale must throw")
            } catch {
                XCTAssertEqual(error as? VideoUpscalingError, .invalidScale)
            }
        }
        let actual = await subject.configuration(for: camera)
        XCTAssertEqual(actual, enabled)
    }

    func test_callIsolationAndTeardown_restoreOff() async throws {
        let otherCall = VideoUpscalingController()
        try await subject.set(enabled, for: .all)
        let other = await otherCall.configuration(for: camera)
        XCTAssertEqual(other, .off)
        await subject.disconnect(reconnecting: false)
        let cleared = await subject.configuration(for: camera)
        XCTAssertEqual(cleared, .off)
    }

    func test_resetDefault_keepsTrackOverride() async throws {
        try await subject.set(enabled, for: .all)
        let override = VideoUpscalingConfiguration(backend: .metalFX, scale: 3)
        try await subject.set(override, for: .track(camera))
        await subject.reset(for: .all)
        let cameraValue = await subject.configuration(for: camera)
        let screenValue = await subject.configuration(for: screen)
        XCTAssertEqual(cameraValue, override)
        XCTAssertEqual(screenValue, .off)
    }

    func test_replacedReceiver_cannotPublishStaleStatus() async throws {
        let first = Receiver()
        let replacement = Receiver()
        await subject.attach(first, for: camera)
        let oldCallback = first.status
        await subject.attach(replacement, for: camera)
        let received = expectation(description: "Current status")
        let stale = expectation(description: "Stale status")
        stale.isInverted = true
        let subscription = subject.statuses.sink { [camera] values in
            if values[camera]?.enhancedFrames == 7 { received.fulfill() }
            if values[camera]?.enhancedFrames == 99 { stale.fulfill() }
        }
        replacement.status?(status(enhancedFrames: 7), 1)
        await fulfillment(of: [received], timeout: 2)
        oldCallback?(status(enhancedFrames: 99), 2)
        await fulfillment(of: [stale], timeout: 0.1)
        subscription.cancel()
    }

    func test_capabilities_beforeArrivalIncludeRuntimeSupport() async {
        let capabilities = await subject.capabilities(for: camera)
        XCTAssertEqual(capabilities.inputWidth, 0)
        XCTAssertEqual(capabilities.backends.count, 3)
        XCTAssertEqual(capabilities.backends.first { $0.backend == .off }?.isSupported, true)
        XCTAssertEqual(capabilities.backends.first { $0.backend == .videoToolbox }?.scaleFactors, [])
    }

    func test_invalidOptionsAndTarget_throwWithoutAttaching() async {
        do {
            try await subject.set(.init(backend: .videoToolbox, highPrecision: true), for: .all)
            XCTFail("MetalFX options require MetalFX")
        } catch {
            XCTAssertEqual(error as? VideoUpscalingError, .invalidMetalFXOptions)
        }
        do {
            try await subject.set(enabled, for: .track(.init(participantSessionID: "")))
            XCTFail("A track needs a participant session")
        } catch {
            XCTAssertEqual(error as? VideoUpscalingError, .emptyParticipantSessionID)
        }
    }

    func test_sameReceiver_outOfOrderSnapshotDoesNotRegressState() async {
        let receiver = Receiver()
        await subject.attach(receiver, for: camera)
        let current = expectation(description: "Current status")
        let stale = expectation(description: "Old status")
        stale.isInverted = true
        let subscription = subject.statuses.sink { [camera] values in
            if values[camera]?.enhancedFrames == 99 { current.fulfill() }
            if values[camera]?.enhancedFrames == 7 { stale.fulfill() }
        }
        receiver.status?(status(enhancedFrames: 99), 2)
        await fulfillment(of: [current], timeout: 2)
        receiver.status?(status(enhancedFrames: 7, inputWidth: 640), 1)
        await fulfillment(of: [stale], timeout: 0.1)
        subscription.cancel()
        let capabilities = await subject.capabilities(for: camera)
        XCTAssertEqual(capabilities.inputWidth, 320)
    }

    private func status(enhancedFrames: UInt64, inputWidth: Int = 320) -> VideoUpscalingStatus {
        .init(
            configuration: .off,
            effectiveBackend: .off,
            state: .passthrough,
            fallbackReason: nil,
            inputWidth: inputWidth,
            inputHeight: 180,
            outputWidth: 320,
            outputHeight: 180,
            processingMilliseconds: 0,
            enhancedFrames: enhancedFrames,
            bypassedFrames: 0
        )
    }

    private final class Receiver: VideoUpscalingReceiving, @unchecked Sendable {
        var configurations: [VideoUpscalingConfiguration] = []
        var detachCount = 0
        var status: (@Sendable (VideoUpscalingStatus, UInt64) -> Void)?

        func apply(
            _ configuration: VideoUpscalingConfiguration,
            status: @escaping @Sendable (VideoUpscalingStatus, UInt64) -> Void
        ) {
            configurations.append(configuration)
            self.status = status
        }

        func detach() { detachCount += 1 }
    }
}
