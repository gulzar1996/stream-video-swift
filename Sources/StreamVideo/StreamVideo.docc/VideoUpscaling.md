# Upscale received video

Apply optional processing to a remote participant's camera or screen share.

## Overview

Video upscaling runs after decoding and before a track delivers frames to its
renderers. It changes local playback only. It does not increase the resolution
sent by another participant or change the negotiated codec.

The default is Off. MetalFX Spatial requires iOS 16 and compatible hardware.
VideoToolbox Low Latency requires iOS 26 and compatible hardware. Simulator
builds deliver original frames. Runtime capability queries describe support on
the current device.

This feature requires the custom local `StreamWebRTC` binary. Follow the local
build instructions in `TestTools/VideoUpscaling/README.md` before building the
SDK or demo.

## Configure a call or track

Set a call default before or after joining:

```swift
try await call.setVideoUpscaling(.init(backend: .metalFX))
```

Enabled processing defaults to 2× scale. MetalFX defaults to perceptual color
and 8-bit intermediate textures. It also supports linear color and 16-bit float
intermediate textures:

```swift
let screen = VideoUpscalingTrack(
    participantSessionID: participant.sessionId,
    source: .screenShare
)
try await call.setVideoUpscaling(
    .init(backend: .metalFX, scale: 2, colorMode: .linear, highPrecision: true),
    for: .track(screen)
)
```

A track override takes precedence over the call default. Camera and screen-share
overrides are independent. A setting can be stored before the track arrives.
Use the participant's session ID, rather than their user ID.

Reset an override to restore inheritance:

```swift
await call.resetVideoUpscaling(for: .track(screen))
```

Resetting `.all` restores the call default to Off and retains track overrides.
Settings survive reconnects and receiver replacements. Participant departure
removes that session's overrides. Leaving the call clears settings and releases
native processing resources.

## Query support and observe results

```swift
let capabilities = await call.videoUpscalingCapabilities(for: screen)
let status = call.state.videoUpscalingStatuses[screen]
```

MetalFX offers 1.5×, 2×, 3×, and 4×. VideoToolbox scale choices depend on the
observed input size; its scale list is empty before a frame size is known.
Capability queries filter out sizes above 3840×2160, or its portrait equivalent.
Oversized input passes through without being downscaled.

Status distinguishes the requested configuration from the effective backend.
It includes preparing, active, or passthrough state; a fallback reason;
input/output dimensions; processing time; and enhanced/bypassed frame counts.
Frame counters describe the current receiver. Status counters are published at
most five times per second while the effective state stays unchanged. State and
input-size changes are published immediately.

Invalid settings throw and leave the previous setting intact. Runtime
limitations deliver original frames and publish a reason. The processor does
not switch backends automatically. Unsupported formats and HDR pass through.
Only one processing operation runs per receiver. Busy frames use the original;
a 33 ms deadline prevents late enhanced frames from replacing newer playback.

## Topics

### Configuration

- ``VideoUpscalingConfiguration``
- ``VideoUpscalingTarget``
- ``VideoUpscalingTrack``
- ``VideoUpscalingError``

### Runtime information

- ``VideoUpscalingCapabilities``
- ``VideoUpscalingCapability``
- ``VideoUpscalingStatus``
