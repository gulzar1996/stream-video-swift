//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Combine
import Foundation
import StreamWebRTC

protocol VideoUpscalingReceiving: AnyObject, Sendable {
    func apply(
        _ configuration: VideoUpscalingConfiguration,
        status: @escaping @Sendable (VideoUpscalingStatus, UInt64) -> Void
    )
    func detach()
}

/// Owns settings across receiver replacements within one call.
actor VideoUpscalingController {
    struct Settings: Sendable, Equatable {
        let defaultConfiguration: VideoUpscalingConfiguration
        let overrides: [VideoUpscalingTrack: VideoUpscalingConfiguration]
    }

    nonisolated let settings = CurrentValueSubject<Settings, Never>(
        .init(defaultConfiguration: .off, overrides: [:])
    )

    nonisolated let statuses = CurrentValueSubject<
        [VideoUpscalingTrack: VideoUpscalingStatus], Never
    >([:])

    private struct Entry {
        let receiver: VideoUpscalingReceiving
        var configuration: VideoUpscalingConfiguration?
        var generation = UUID()
        var sequence: UInt64 = 0
    }

    private var defaultConfiguration: VideoUpscalingConfiguration = .off
    private var overrides: [VideoUpscalingTrack: VideoUpscalingConfiguration] = [:]
    private var receivers: [VideoUpscalingTrack: Entry] = [:]
    private var currentStatuses: [VideoUpscalingTrack: VideoUpscalingStatus] = [:]
    private var lastPublished: [VideoUpscalingTrack: TimeInterval] = [:]

    func set(_ configuration: VideoUpscalingConfiguration, for target: VideoUpscalingTarget) throws {
        guard configuration.scale.isFinite, configuration.scale > 1 else {
            throw VideoUpscalingError.invalidScale
        }
        if configuration.backend == .metalFX, ![1.5, 2, 3, 4].contains(configuration.scale) {
            throw VideoUpscalingError.invalidScale
        }
        if configuration.backend != .metalFX,
           configuration.colorMode != .perceptual || configuration.highPrecision {
            throw VideoUpscalingError.invalidMetalFXOptions
        }
        switch target {
        case .all:
            defaultConfiguration = configuration
            for track in receivers.keys where overrides[track] == nil { apply(for: track) }
        case let .track(track):
            guard !track.participantSessionID.isEmpty else {
                throw VideoUpscalingError.emptyParticipantSessionID
            }
            overrides[track] = configuration
            apply(for: track)
        }
        publishSettings()
    }

    func reset(for target: VideoUpscalingTarget) {
        switch target {
        case .all:
            defaultConfiguration = .off
            for track in receivers.keys where overrides[track] == nil { apply(for: track) }
        case let .track(track):
            overrides[track] = nil
            apply(for: track)
        }
        publishSettings()
    }

    func configuration(for track: VideoUpscalingTrack) -> VideoUpscalingConfiguration {
        overrides[track] ?? defaultConfiguration
    }

    func attach(_ receiver: VideoUpscalingReceiving, for track: VideoUpscalingTrack) {
        if receivers[track]?.receiver === receiver { return }
        remove(track)
        receivers[track] = .init(receiver: receiver)
        apply(for: track)
    }

    func remove(_ track: VideoUpscalingTrack, matching receiver: VideoUpscalingReceiving? = nil) {
        if let receiver, receivers[track]?.receiver !== receiver { return }
        let previous = receivers.removeValue(forKey: track)
        previous?.receiver.detach()
        currentStatuses[track] = nil
        lastPublished[track] = nil
        if statuses.value[track] != nil {
            var published = statuses.value
            published[track] = nil
            statuses.send(published)
        }
    }

    func participantLeft(_ sessionID: String) {
        overrides = overrides.filter { $0.key.participantSessionID != sessionID }
        publishSettings()
        for track in Array(receivers.keys) where track.participantSessionID == sessionID {
            remove(track)
        }
    }

    func disconnect(reconnecting: Bool) {
        for track in Array(receivers.keys) { remove(track) }
        if !reconnecting {
            overrides.removeAll()
            defaultConfiguration = .off
            publishSettings()
        }
    }

    private func publishSettings() {
        settings.send(.init(defaultConfiguration: defaultConfiguration, overrides: overrides))
    }

    func capabilities(for track: VideoUpscalingTrack) -> VideoUpscalingCapabilities {
        let status = currentStatuses[track]
        let width = status?.inputWidth ?? 0
        let height = status?.inputHeight ?? 0
        return .init(
            inputWidth: width,
            inputHeight: height,
            backends:
            VideoUpscalingConfiguration.Backend.allCases.map { backend in
                .init(
                    backend: backend,
                    isSupported: RTCVideoUpscalingConfiguration.isBackendSupported(backend.native),
                    scaleFactors: RTCVideoUpscalingConfiguration.supportedScaleFactors(
                        for: backend.native, width: width, height: height
                    ).map(\.doubleValue)
                )
            }
        )
    }

    private func apply(for track: VideoUpscalingTrack) {
        guard var entry = receivers[track] else { return }
        let configuration = configuration(for: track)
        guard entry.configuration != configuration else { return }
        entry.configuration = configuration
        entry.generation = UUID()
        entry.sequence = 0
        receivers[track] = entry
        let generation = entry.generation
        entry.receiver.apply(configuration) { [weak self] status, sequence in
            Task { await self?.receive(status, for: track, generation: generation, sequence: sequence) }
        }
    }

    private func receive(
        _ status: VideoUpscalingStatus,
        for track: VideoUpscalingTrack,
        generation: UUID,
        sequence: UInt64
    ) {
        guard var entry = receivers[track], entry.generation == generation,
              sequence > entry.sequence else { return }
        entry.sequence = sequence
        receivers[track] = entry
        currentStatuses[track] = status
        let previous = statuses.value[track]
        let now = ProcessInfo.processInfo.systemUptime
        let changed = previous?.configuration != status.configuration
            || previous?.state != status.state
            || previous?.effectiveBackend != status.effectiveBackend
            || previous?.fallbackReason != status.fallbackReason
            || previous?.inputWidth != status.inputWidth
            || previous?.inputHeight != status.inputHeight
        guard changed || now - (lastPublished[track] ?? 0) >= 0.2 else { return }
        lastPublished[track] = now
        var published = statuses.value
        published[track] = status
        statuses.send(published)
    }
}

extension VideoUpscalingConfiguration.Backend {
    var native: RTCVideoUpscalingBackend {
        switch self {
        case .off: return .off
        case .videoToolbox: return .videoToolbox
        case .metalFX: return .metalFX
        }
    }
}
