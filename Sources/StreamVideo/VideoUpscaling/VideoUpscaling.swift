//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation

/// Processing applied to decoded remote video. Outgoing video is unchanged.
public struct VideoUpscalingConfiguration: Sendable, Hashable {
    /// The requested processor. Runtime failures use the original frame.
    public enum Backend: String, Sendable, CaseIterable {
        case off
        case videoToolbox
        case metalFX
    }

    /// MetalFX's intermediate color space.
    public enum ColorMode: String, Sendable, CaseIterable {
        case perceptual
        case linear
    }

    public var backend: Backend
    public var scale: Double
    public var colorMode: ColorMode
    public var highPrecision: Bool

    /// Creates options. Settings are validated when applied to a call.
    public init(
        backend: Backend = .off,
        scale: Double = 2,
        colorMode: ColorMode = .perceptual,
        highPrecision: Bool = false
    ) {
        self.backend = backend
        self.scale = scale
        self.colorMode = colorMode
        self.highPrecision = highPrecision
    }

    public static let off = Self()
}

/// A remote track identified by participant session and media source.
public struct VideoUpscalingTrack: Sendable, Hashable {
    public enum Source: String, Sendable, CaseIterable {
        case camera
        case screenShare
    }

    public let participantSessionID: String
    public let source: Source

    public init(participantSessionID: String, source: Source = .camera) {
        self.participantSessionID = participantSessionID
        self.source = source
    }
}

/// A track override takes precedence over the call default.
public enum VideoUpscalingTarget: Sendable, Hashable {
    case all
    case track(VideoUpscalingTrack)
}

/// Invalid requests leave the current configuration unchanged.
public enum VideoUpscalingError: Error, Sendable, Equatable {
    case invalidScale
    case invalidMetalFXOptions
    case emptyParticipantSessionID
}

/// Runtime support for one backend at the last observed input size.
public struct VideoUpscalingCapability: Sendable, Equatable {
    public let backend: VideoUpscalingConfiguration.Backend
    public let isSupported: Bool
    public let scaleFactors: [Double]
}

/// Current device support. VideoToolbox scales need a known input size.
public struct VideoUpscalingCapabilities: Sendable, Equatable {
    public let inputWidth: Int
    public let inputHeight: Int
    public let backends: [VideoUpscalingCapability]
}

/// The most recent processing result for a received track.
public struct VideoUpscalingStatus: Sendable, Equatable {
    public enum State: String, Sendable {
        case preparing
        case active
        case passthrough
    }

    public let configuration: VideoUpscalingConfiguration
    public let effectiveBackend: VideoUpscalingConfiguration.Backend
    public let state: State
    /// A diagnostic reason, such as `busy`, `hdrInput`, or `outputLimit`.
    public let fallbackReason: String?
    public let inputWidth: Int
    public let inputHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let processingMilliseconds: Double
    public let enhancedFrames: UInt64
    public let bypassedFrames: UInt64
}
