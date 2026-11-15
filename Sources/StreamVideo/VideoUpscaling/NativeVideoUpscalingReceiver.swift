//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
import StreamWebRTC

/// Access is serialized by the owning upscaling controller.
final class NativeVideoUpscalingReceiver: VideoUpscalingReceiving, @unchecked Sendable {
    private let receiver: RTCRtpReceiver

    init(_ receiver: RTCRtpReceiver) {
        self.receiver = receiver
    }

    func apply(
        _ configuration: VideoUpscalingConfiguration,
        status: @escaping @Sendable (VideoUpscalingStatus, UInt64) -> Void
    ) {
        receiver.setVideoUpscalingConfiguration(
            .init(
                backend: configuration.backend.native,
                scale: configuration.scale,
                linearColor: configuration.colorMode == .linear,
                highPrecision: configuration.highPrecision
            )
        ) { snapshot in
            status(.init(
                configuration: configuration,
                effectiveBackend: .init(snapshot.effectiveBackend),
                state: .init(snapshot.state),
                fallbackReason: snapshot.fallbackReason,
                inputWidth: snapshot.inputWidth,
                inputHeight: snapshot.inputHeight,
                outputWidth: snapshot.outputWidth,
                outputHeight: snapshot.outputHeight,
                processingMilliseconds: snapshot.processingMilliseconds,
                enhancedFrames: snapshot.enhancedFrames,
                bypassedFrames: snapshot.bypassedFrames
            ), snapshot.sequence)
        }
    }

    func detach() {
        receiver.setVideoUpscalingConfiguration(
            .init(backend: .off, scale: 2, linearColor: false, highPrecision: false),
            statusHandler: nil
        )
    }
}

private extension VideoUpscalingConfiguration.Backend {
    init(_ native: RTCVideoUpscalingBackend) {
        switch native {
        case .metalFX: self = .metalFX
        case .videoToolbox: self = .videoToolbox
        default: self = .off
        }
    }
}

private extension VideoUpscalingStatus.State {
    init(_ native: RTCVideoUpscalingState) {
        switch native {
        case .preparing: self = .preparing
        case .active: self = .active
        default: self = .passthrough
        }
    }
}
