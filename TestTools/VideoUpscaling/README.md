# Local received-video upscaling

This checkout builds a custom `StreamWebRTC` binary for iOS and iPadOS.
The SDK package, Xcode project, and documentation example project use the same
local package at `LocalPackages/StreamWebRTC`.

## Build

Use macOS with Xcode, Python 3, Git, and XcodeGen. Select Xcode with an iOS SDK
that includes VideoToolbox Low Latency APIs (iOS 26 or newer). The scripts do not
install Xcode, runtimes, signing identities, or global tools.

From the repository root:

```sh
python3 Scripts/webrtc.py setup
python3 Scripts/webrtc.py build --jobs 8
python3 Scripts/webrtc.py verify
```

Setup clones GetStream/webrtc tag `156.0.5`, revision
`15d3e9678dc073629a277d5ee9336dfb7132c7f1`, into ignored
`.webrtc-work/webrtc/src`. Depot Tools is pinned to
`7a339079d178fbc9c6f6230082843d6e00b2551f`.
The initial native dependency download needs substantial disk space.

Build uses the fork's Make/GN/Ninja pipeline and framework rename step.
It produces device arm64 and simulator arm64/x86_64 slices, without Catalyst.
The binary keeps the iOS 13 deployment target. Newer processing APIs are guarded
and weak-linked. The simulator slices support SDK compilation and passthrough;
MetalFX is absent from the simulator SDK.

Native integration changes live in `Native/Patches`. The processor sources live
in `Native/VideoUpscaling` and are copied into the native checkout.
Repeated application is idempotent. Conflicting patches, unexpected revisions,
and edits to installed overlay files are rejected without discarding the edits.
The scripts never reset or clean an existing checkout. Keep native source,
dependencies, build products, signing details, and logs out of tracked files.

The local XCFramework is generated and ignored. A fresh checkout must build it
before resolving the SDK package. This local dependency is not a distributable
SDK release configuration.

## Use

```swift
try await call.setVideoUpscaling(.init(backend: .metalFX))

let camera = VideoUpscalingTrack(participantSessionID: participant.sessionId)
let capabilities = await call.videoUpscalingCapabilities(for: camera)

try await call.setVideoUpscaling(
    .init(backend: .videoToolbox, scale: 2),
    for: .track(camera)
)
await call.resetVideoUpscaling(for: .track(camera))
```

Off is the default. Enabled processing defaults to 2×. MetalFX offers 1.5×, 2×,
3×, and 4×; perceptual or linear color; and 8-bit or 16-bit float intermediates.
VideoToolbox scales come from runtime queries for the current input size.
The call default applies unless a participant-session camera/screen-share
track has an override. Reset restores inheritance. Reconnects retain settings;
participant departure and call teardown remove the corresponding settings.

Observe `call.state.videoUpscalingStatuses` for effective state and fallback
reasons. A valid request can still pass through because of device support,
input format, HDR, output limits, busy processing, or the 33 ms deadline.
No automatic backend switch occurs. Output is bounded to 3840×2160 or its
portrait equivalent. There is no waiting queue of frames for the GPU.

## Demo controls

During a call, open More controls → Video upscaling. Choose the call default or
a participant's camera or screen share. Select a backend and supported scale,
then Apply. MetalFX also exposes color mode and intermediate precision. Reset
restores inheritance. Effective status shows actual processing and fallback.
Refresh capabilities after the input size changes; VideoToolbox needs a known
input size. Call-default choices use one received track as a representative.

## Physical-device tests

Connect an iPhone with Developer Mode enabled. Use a valid local development
signing identity and provisioning profile. Supply identifiers locally:

```sh
python3 Scripts/webrtc.py test --device '<device-identifier>' --team '<team>'
python3 Scripts/webrtc.py test --scheme NativeSourceTests --device '<device-identifier>' --team '<team>'
python3 Scripts/webrtc.py test --scheme ReceiverTests --device '<device-identifier>' --team '<team>'
python3 Scripts/test_ios_device.py --device '<device-identifier>' --team '<team>' --only VideoUpscalingController_Tests
```

Add `--iterations 10` for repetitions that stop at the first failure.
The SDK runner also accepts `--suite StreamVideoSwiftUITests` and repeatable
`--only TestCase/testMethod` selections. Use repeatable
`--skip TestCase/testMethod` arguments for explicit device exclusions, including
simulator-model snapshots. It derives test source and resource membership and
configured exclusions from the repository Xcode project and test plans, then
uses a signed host with the local SDK package. Test-only compiler conditions
match the repository's Test configuration.

Generated projects, `.xcresult` bundles, binary identities, and diagnostics stay
under `.webrtc-work`. No simulator is installed or launched.

The native harness covers frame admission, deadlines, stale results, color,
scaling, and receiver lifecycle. The loopback connects two local peer
connections without an SFU. It checks decoded frames at two renderers, including
hardware and software codecs, live settings, orientation, dimensions, and image
contrast. Unsupported optional codecs are reported as skipped. Runtime
attachments record frame delivery, processing time, memory footprint, and
thermal state.
The loaded framework UUID must match the custom device binary.

Native C++ source tests use a separate test-support archive. That code is not
linked into the shipping framework. Use the fork's bundled Ninja for that
archive to preserve build-log compatibility with the main build pipeline.

Simulator-model snapshot coverage and iPad runtime behavior require separate
validation. An iPad build alone does not establish runtime behavior.
