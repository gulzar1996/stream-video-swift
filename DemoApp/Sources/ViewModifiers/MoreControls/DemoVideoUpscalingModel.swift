//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Combine
import Foundation
import StreamVideo

@MainActor
final class DemoVideoUpscalingModel: ObservableObject {
    let call: Call
    @Published var target: VideoUpscalingTarget = .all
    @Published var configuration: VideoUpscalingConfiguration = .off {
        didSet {
            guard liveUpdates, !synchronizing, configuration != oldValue else { return }
            applyToAll()
        }
    }

    @Published var capabilities: VideoUpscalingCapabilities?
    @Published var error: String?

    private let liveUpdates: Bool
    private var synchronizing = false
    private var pendingConfiguration: VideoUpscalingConfiguration?
    private var liveUpdateTask: Task<Void, Never>?

    init(call: Call, liveUpdates: Bool = false) {
        self.call = call
        self.liveUpdates = liveUpdates
        _configuration = Published(initialValue: call.state.videoUpscalingDefault)
    }

    func synchronize(_ configuration: VideoUpscalingConfiguration) {
        guard liveUpdateTask == nil else { return }
        synchronizing = true
        self.configuration = configuration
        synchronizing = false
    }

    func applyToAll() {
        guard liveUpdates else { return }
        pendingConfiguration = configuration
        applyLiveConfiguration()
    }

    private func applyLiveConfiguration() {
        guard liveUpdateTask == nil else { return }
        liveUpdateTask = Task {
            defer { liveUpdateTask = nil }
            while let next = pendingConfiguration {
                pendingConfiguration = nil
                do {
                    try await call.setVideoUpscaling(next)
                    // The call-screen controls apply to every received track.
                    for track in Array(call.state.videoUpscalingOverrides.keys) {
                        await call.resetVideoUpscaling(for: .track(track))
                    }
                    if configuration == next { error = nil }
                } catch {
                    if configuration == next { self.error = String(describing: error) }
                }
            }
        }
    }

    func select(_ target: VideoUpscalingTarget) async {
        self.target = target
        error = nil
        switch target {
        case .all:
            configuration = call.state.videoUpscalingDefault
        case let .track(track):
            configuration = call.state.videoUpscalingOverrides[track]
                ?? call.state.videoUpscalingDefault
        }
        await refreshCapabilities()
    }

    func refreshCapabilities() async {
        let selected = target
        let track: VideoUpscalingTrack
        switch selected {
        case .all:
            track = call.state.videoUpscalingStatuses.keys.sorted {
                ($0.participantSessionID, $0.source.rawValue) < ($1.participantSessionID, $1.source.rawValue)
            }.first ?? .init(participantSessionID: "pending")
        case let .track(value):
            track = value
        }
        let result = await call.videoUpscalingCapabilities(for: track)
        guard target == selected else { return }
        capabilities = result
    }

    func apply() async {
        do {
            try await call.setVideoUpscaling(configuration, for: target)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    func reset() async {
        let selected = target
        await call.resetVideoUpscaling(for: selected)
        guard target == selected else { return }
        configuration = selected == .all ? .off : call.state.videoUpscalingDefault
        error = nil
        await refreshCapabilities()
    }

    var scales: [Double] {
        capabilities?.backends.first { $0.backend == configuration.backend }?.scaleFactors ?? []
    }
}
