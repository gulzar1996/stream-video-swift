//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation

extension Call {
    /// Applies received-video processing without rejoining the call.
    /// A track override takes precedence over the call default.
    @MainActor
    public func setVideoUpscaling(
        _ configuration: VideoUpscalingConfiguration,
        for target: VideoUpscalingTarget = .all
    ) async throws {
        try await callController.videoUpscaling.set(configuration, for: target)
    }

    /// Restores track inheritance, or resets the call default to Off.
    @MainActor
    public func resetVideoUpscaling(for target: VideoUpscalingTarget = .all) async {
        await callController.videoUpscaling.reset(for: target)
    }

    /// Queries device support using the track's last observed input size.
    public func videoUpscalingCapabilities(for track: VideoUpscalingTrack) async -> VideoUpscalingCapabilities {
        await callController.videoUpscaling.capabilities(for: track)
    }
}
