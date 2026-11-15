//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
@testable import StreamVideo
import SwiftUI
import XCTest

@MainActor
final class DemoVideoUpscalingModel_Tests: StreamVideoTestCase, @unchecked Sendable {
    func test_liveConfiguration_applyUnchangedOffClearsOverrides() async throws {
        let call = streamVideo.call(callType: "default", callId: "live-scaler-off")
        defer { call.leave() }
        let track = VideoUpscalingTrack(participantSessionID: "remote")
        try await call.setVideoUpscaling(.init(backend: .metalFX), for: .track(track))
        await fulfilmentInMainActor { call.state.videoUpscalingOverrides[track] != nil }
        let subject = DemoVideoUpscalingModel(call: call, liveUpdates: true)
        XCTAssertEqual(subject.configuration, .off)

        subject.applyToAll()

        await fulfilmentInMainActor { call.state.videoUpscalingOverrides.isEmpty }
        XCTAssertEqual(call.state.videoUpscalingDefault, .off)
    }

    func test_liveConfiguration_changesApplyWithoutApplyButton() async {
        let call = streamVideo.call(callType: "default", callId: "live-scaler")
        defer { call.leave() }
        let subject = DemoVideoUpscalingModel(call: call, liveUpdates: true)

        for backend in [VideoUpscalingConfiguration.Backend.metalFX, .videoToolbox, .off] {
            let configuration = VideoUpscalingConfiguration(backend: backend, scale: 3)
            subject.configuration = configuration
            await fulfilmentInMainActor { call.state.videoUpscalingDefault == configuration }
        }
        XCTAssertNil(subject.error)
    }

    func test_liveConfiguration_rapidChangesApplyLatestAndClearTrackOverrides() async throws {
        let call = streamVideo.call(callType: "default", callId: "live-scaler-latest")
        defer { call.leave() }
        let track = VideoUpscalingTrack(participantSessionID: "remote")
        try await call.setVideoUpscaling(.init(backend: .metalFX), for: .track(track))
        await fulfilmentInMainActor { call.state.videoUpscalingOverrides[track] != nil }
        let subject = DemoVideoUpscalingModel(call: call, liveUpdates: true)

        subject.configuration = .init(backend: .metalFX, scale: 1.5)
        await Task.yield()
        subject.configuration = .init(backend: .videoToolbox, scale: 2)
        subject.configuration = .init(backend: .metalFX, scale: 4)
        await fulfilmentInMainActor {
            call.state.videoUpscalingDefault == .init(backend: .metalFX, scale: 4)
                && call.state.videoUpscalingOverrides.isEmpty
        }
        subject.configuration = .off
        await fulfilmentInMainActor { call.state.videoUpscalingDefault == .off }
        XCTAssertNil(subject.error)
    }

    func test_manualConfiguration_editDoesNotApplyUntilRequested() async {
        let call = streamVideo.call(callType: "default", callId: "manual-scaler")
        defer { call.leave() }
        let subject = DemoVideoUpscalingModel(call: call)
        subject.configuration = .init(backend: .metalFX, scale: 4)
        await subject.refreshCapabilities()
        XCTAssertEqual(call.state.videoUpscalingDefault, .off)
        await subject.apply()
        await fulfilmentInMainActor {
            call.state.videoUpscalingDefault == .init(backend: .metalFX, scale: 4)
        }
    }

    func test_liveConfiguration_externalSettingsSynchronizeWithoutClearingOverrides() async throws {
        let call = streamVideo.call(callType: "default", callId: "live-scaler-sync")
        defer { call.leave() }
        let track = VideoUpscalingTrack(participantSessionID: "remote")
        try await call.setVideoUpscaling(.off, for: .track(track))
        let enabled = VideoUpscalingConfiguration(backend: .metalFX, scale: 3)
        try await call.setVideoUpscaling(enabled)
        await fulfilmentInMainActor { call.state.videoUpscalingDefault == enabled }
        let subject = DemoVideoUpscalingModel(call: call, liveUpdates: true)
        XCTAssertEqual(subject.configuration, enabled)

        subject.synchronize(.off)
        await subject.refreshCapabilities()
        XCTAssertEqual(subject.configuration, .off)
        XCTAssertEqual(call.state.videoUpscalingDefault, enabled)
        XCTAssertEqual(call.state.videoUpscalingOverrides[track], .off)
    }

    func test_bottomControlsRenderOnDevice() async throws {
        let call = streamVideo.call(callType: "default", callId: "bottom-scaler-preview")
        defer { call.leave() }
        try await call.setVideoUpscaling(.init(backend: .metalFX))
        await fulfilmentInMainActor { call.state.videoUpscalingDefault.backend == .metalFX }
        let subject = UIHostingController(rootView:
            VStack {
                Spacer()
                DemoVideoUpscalingBar(call: call).padding()
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = subject
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        subject.view.layoutIfNeeded()
        await fulfilmentInMainActor { subject.view.window != nil }
        let renderer = UIGraphicsImageRenderer(bounds: subject.view.bounds)
        let image = renderer.image { _ in
            subject.view.drawHierarchy(in: subject.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Bottom video scaler"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test_controlsRenderOnDevice() async throws {
        let call = streamVideo.call(callType: "default", callId: "demo-preview")
        defer { call.leave() }
        call.state.remoteParticipants = [.dummy(name: "Alex", sessionId: "remote")]
        try await call.setVideoUpscaling(.init(backend: .metalFX))
        await fulfilmentInMainActor { call.state.videoUpscalingDefault.backend == .metalFX }
        let subject = UIHostingController(rootView: DemoVideoUpscalingView(call: call))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = subject
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        subject.view.layoutIfNeeded()
        await fulfilmentInMainActor { subject.view.window != nil }
        let renderer = UIGraphicsImageRenderer(bounds: subject.view.bounds)
        let image = renderer.image { _ in
            subject.view.drawHierarchy(in: subject.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Video upscaling controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test_selectionAndReset_followCameraAndScreenShareInheritance() async throws {
        let call = streamVideo.call(callType: "default", callId: "demo-controls")
        defer { call.leave() }
        let enabled = VideoUpscalingConfiguration(backend: .metalFX)
        let camera = VideoUpscalingTrack(participantSessionID: "remote")
        let screen = VideoUpscalingTrack(participantSessionID: "remote", source: .screenShare)
        try await call.setVideoUpscaling(enabled)
        try await call.setVideoUpscaling(.off, for: .track(camera))
        await fulfilmentInMainActor { call.state.videoUpscalingDefault == enabled }
        await fulfilmentInMainActor { call.state.videoUpscalingOverrides[camera] == .off }
        let subject = DemoVideoUpscalingModel(call: call)
        await subject.select(.track(screen))
        XCTAssertEqual(subject.target, .track(screen))
        XCTAssertEqual(subject.configuration, enabled)
        XCTAssertEqual(subject.scales, [1.5, 2, 3, 4])
        await subject.select(.track(camera))
        XCTAssertEqual(subject.configuration, .off)
        await subject.reset()
        await fulfilmentInMainActor { call.state.videoUpscalingOverrides[camera] == nil }
        XCTAssertEqual(subject.configuration, enabled)
    }

    func test_apply_reportsInvalidSettingsAndPreservesPreviousConfiguration() async {
        let call = streamVideo.call(callType: "default", callId: "demo-invalid")
        defer { call.leave() }
        let subject = DemoVideoUpscalingModel(call: call)
        subject.configuration = .init(backend: .metalFX, scale: 1.7)
        await subject.apply()
        XCTAssertNotNil(subject.error)
        XCTAssertEqual(call.state.videoUpscalingDefault, .off)
        subject.configuration = .init(backend: .metalFX, scale: 3)
        await subject.apply()
        await fulfilmentInMainActor { call.state.videoUpscalingDefault.scale == 3 }
        XCTAssertNil(subject.error)
    }
}
