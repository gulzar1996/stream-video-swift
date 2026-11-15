#!/usr/bin/env python3
"""Build the pinned local StreamWebRTC framework."""

from pathlib import Path
import hashlib
import json
import subprocess


def synchronize_overlay(overlay, destination, record):
    """Update owned sources only when their last installed content is intact."""
    previous = json.loads(record.read_text()) if record.exists() else {}
    contents = {
        path.name: path.read_bytes()
        for path in sorted(overlay.iterdir())
        if path.suffix in (".h", ".mm", ".cc")
    }
    for name, content in contents.items():
        target = destination / name
        if target.is_symlink():
            raise RuntimeError(f"Native overlay conflict: {name} is a symlink")
        if target.exists():
            installed = target.read_bytes()
            if installed != content and previous.get(name) != hashlib.sha256(installed).hexdigest():
                raise RuntimeError(f"Native overlay conflict: {name}")
    destination.mkdir(parents=True, exist_ok=True)
    for name, content in contents.items():
        target = destination / name
        if not target.exists() or target.read_bytes() != content:
            target.write_bytes(content)
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({
        name: hashlib.sha256(content).hexdigest()
        for name, content in contents.items()
    }, indent=2) + "\n")


def apply_patches(source, patches):
    """Preflight the entire patch set before changing the native checkout."""
    pending = []
    for patch in sorted(Path(patches).glob("*.patch")):
        patch = str(patch.resolve())
        command = ["git", "-C", str(source), "apply", "--check"]
        forward = subprocess.run(command + [patch], capture_output=True)
        if forward.returncode == 0:
            pending.append(patch)
        elif subprocess.run(
            command + ["--reverse", patch], capture_output=True
        ).returncode != 0:
            raise RuntimeError(f"Native patch conflict: {Path(patch).name}")
    if pending:
        command = ["git", "-C", str(source), "apply"]
        result = subprocess.run(command + ["--check"] + pending, capture_output=True)
        if result.returncode:
            raise RuntimeError("Native patch conflict in combined patch set")
        subprocess.run(command + pending, check=True)


def verify_checkout(source, revision):
    if source.is_symlink():
        raise RuntimeError("Refusing a symlink checkout")
    if not (source / ".git").exists():
        raise RuntimeError("Existing native directory is not a checkout")
    actual = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != revision:
        raise RuntimeError(f"Unexpected checkout revision: {actual}")


NATIVE_REVISION = "15d3e9678dc073629a277d5ee9336dfb7132c7f1"
DEPOT_REVISION = "7a339079d178fbc9c6f6230082843d6e00b2551f"
NATIVE_URL = "https://github.com/GetStream/webrtc.git"
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".webrtc-work"
SOURCE = WORK / "webrtc/src"
DEPOT = WORK / "depot_tools"
RENAMED = WORK / "webrtc/products/renamed/StreamWebRTC.xcframework"
LOCAL_BINARY = ROOT / "LocalPackages/StreamWebRTC/StreamWebRTC.xcframework"


def run(arguments, **kwargs):
    print("+", " ".join(map(str, arguments)), flush=True)
    return subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def build_environment():
    import os
    environment = os.environ.copy()
    environment["PATH"] = str(DEPOT) + os.pathsep + environment["PATH"]
    environment["DEPOT_TOOLS_UPDATE"] = "0"
    return environment


def make(*arguments):
    run(["make", "-C", SOURCE / "stream_build", f"WEBRTC_REPO={NATIVE_URL}", *arguments],
        env=build_environment())


def setup():
    WORK.mkdir(exist_ok=True)
    if not SOURCE.exists():
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--branch", "156.0.5", "--single-branch",
             NATIVE_URL, SOURCE])
    verify_checkout(SOURCE, NATIVE_REVISION)
    if not DEPOT.exists():
        run(["git", "clone", "--no-checkout",
             "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
             DEPOT])
        run(["git", "-C", DEPOT, "checkout", "--detach", DEPOT_REVISION])
    verify_checkout(DEPOT, DEPOT_REVISION)
    make("bootstrap", "CONFIRM=1", f"WEBRTC_REPO={NATIVE_URL}", "TARGET_OS=ios")
    make("deps", "TARGET_OS=ios", "RUN_HOOKS=0", "SYNC_JOBS=4")
    make("runhooks", "TARGET_OS=ios")


def prepare_sources():
    verify_checkout(SOURCE, NATIVE_REVISION)
    synchronize_overlay(ROOT / "Native/VideoUpscaling",
                        SOURCE / "sdk/objc/components/video_upscaling",
                        WORK / "overlay.json")
    synchronize_overlay(ROOT / "TestTools/VideoUpscaling/NativeSource",
                        SOURCE / "stream_video_tests", WORK / "test-overlay.json")
    apply_patches(SOURCE, ROOT / "Native/Patches")


def build(jobs):
    import shutil
    prepare_sources()
    make("build", "ios", "SKIP_DEPS=1", "SKIP_MACCATALYST=1", f"JOBS={jobs}")
    make("package", "ios", "SKIP_DEPS=1", "SKIP_MACCATALYST=1", "ZIP=0")
    make("rename", "apple",
         f"XCFRAMEWORK={WORK / 'webrtc/products/ios/WebRTC.xcframework'}")
    verify_artifact(RENAMED)
    LOCAL_BINARY.parent.mkdir(parents=True, exist_ok=True)
    if LOCAL_BINARY.is_symlink():
        raise RuntimeError("Refusing a symlink binary destination")
    if LOCAL_BINARY.exists():
        shutil.rmtree(LOCAL_BINARY)
    shutil.copytree(RENAMED, LOCAL_BINARY)
    verify_artifact(LOCAL_BINARY)


def verify_artifact(artifact):
    import plistlib
    info = plistlib.loads((artifact / "Info.plist").read_bytes())
    slices = info["AvailableLibraries"]
    identities = []
    device_architectures = set()
    simulator_architectures = set()
    for item in slices:
        if item["SupportedPlatform"] != "ios":
            raise RuntimeError("Only iOS/iPadOS slices are supported")
        variant = item.get("SupportedPlatformVariant", "device")
        if variant not in ("device", "simulator"):
            raise RuntimeError(f"Unexpected platform variant: {variant}")
        architectures = set(item["SupportedArchitectures"])
        (device_architectures if variant == "device" else
         simulator_architectures).update(architectures)
        framework = artifact / item["LibraryIdentifier"] / item["LibraryPath"]
        header = (framework / "Headers/RTCRtpReceiver.h").read_text()
        if "setVideoUpscalingConfiguration:" not in header:
            raise RuntimeError("Missing custom receiver API")
        binary = framework / "StreamWebRTC"
        symbols = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
        for symbol in ("_OBJC_CLASS_$_RTCVideoUpscalingConfiguration",
                       "_OBJC_CLASS_$_RTCVideoUpscalingStatus"):
            if symbol not in symbols:
                raise RuntimeError(f"Missing custom symbol: {symbol}")
        uuids = subprocess.check_output(["dwarfdump", "--uuid", str(binary)], text=True)
        identities.append({"slice": item["LibraryIdentifier"],
                           "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                           "uuids": [line.split(" (")[0] for line in uuids.splitlines()],
                           "bytes": binary.stat().st_size})
    if device_architectures != {"arm64"} or simulator_architectures != {"arm64", "x86_64"}:
        raise RuntimeError("Missing or unexpected framework architectures")
    WORK.mkdir(exist_ok=True)
    (WORK / "binary-identity.json").write_text(json.dumps({
        "nativeRevision": NATIVE_REVISION, "slices": identities
    }, indent=2) + "\n")
    print(json.dumps(identities, indent=2))


def device_tests(device, team, scheme, iterations, jobs):
    import datetime
    import re
    if not re.fullmatch(r"[A-Za-z0-9-]+", device):
        raise RuntimeError("Supply a physical iOS device identifier")
    if not re.fullmatch(r"[A-Za-z0-9]+", team):
        raise RuntimeError("Supply a local signing team identifier")
    if scheme == "NativeSourceTests":
        prepare_sources()
        run([SOURCE / "third_party/ninja/ninja", "-C", WORK / "webrtc/out/ios-arm64-device",
             "pc:video_upscaling_test_support", f"-j{jobs}"], env=build_environment())
        output = WORK / "webrtc/out/ios-arm64-device"
        archive = output / "obj/pc/libdevice_source_tests.a"
        libraries = [output / "obj/pc/libvideo_upscaling_test_support.a",
                     output / "obj/buildtools/third_party/libc++/libc++.a"]
        script = f'CREATE "{archive}"\n' + "".join(
            f'ADDLIB "{path}"\n' for path in libraries
        ) + "SAVE\nEND\n"
        run([SOURCE / "third_party/llvm-build/Release+Asserts/bin/llvm-ar", "-M"],
            input=script, text=True)
    project = WORK / "device-tests"
    project.mkdir(exist_ok=True)
    run(["xcodegen", "generate", "--spec", ROOT / "TestTools/VideoUpscaling/project.yml",
         "--project", project])
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    result_bundle = project / f"{scheme}-{stamp}.xcresult"
    run(["xcodebuild", "test", "-project", project / "VideoUpscalingTests.xcodeproj",
         "-scheme", scheme, "-destination", f"platform=iOS,id={device}",
         "-derivedDataPath", project / f"{scheme}DerivedData",
         "-resultBundlePath", result_bundle,
         f"DEVELOPMENT_TEAM={team}", "-parallel-testing-enabled", "NO"] +
        (["-test-iterations", str(iterations), "-run-tests-until-failure"]
         if iterations > 1 else []))
    if scheme == "ReceiverTests":
        attachments = project / f"identity-{stamp}"
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", result_bundle,
             "--output-path", attachments])
        records = json.loads((attachments / "manifest.json").read_text())
        identities = []
        for test in records:
            for attachment in test.get("attachments", []):
                if attachment.get("suggestedHumanReadableName", "").startswith("StreamWebRTC loaded UUID"):
                    identities.append((attachments / attachment["exportedFileName"]).read_text().strip())
        expected = subprocess.check_output([
            "dwarfdump", "--uuid", str(RENAMED / "ios-arm64/StreamWebRTC.framework/StreamWebRTC")
        ], text=True).split()[1]
        if not identities or any(identity != expected for identity in identities):
            raise RuntimeError(f"Loaded framework identity mismatch: {identities}")
        print(f"Verified loaded StreamWebRTC UUID: {expected}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup", help="Clone pinned sources and fetch native dependencies")
    builder = commands.add_parser("build", help="Build all iOS slices and install the local binary")
    builder.add_argument("--jobs", type=int, default=8)
    commands.add_parser("verify", help="Verify the installed local binary")
    tests = commands.add_parser("test", help="Run signed tests on a physical iOS device")
    tests.add_argument("--device", required=True)
    tests.add_argument("--team", required=True)
    tests.add_argument("--scheme", choices=["VideoUpscalingTests", "ReceiverTests", "NativeSourceTests"],
                       default="VideoUpscalingTests")
    tests.add_argument("--iterations", type=int, default=1)
    tests.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if args.command == "setup":
        setup()
    elif args.command == "build":
        build(args.jobs)
    elif args.command == "verify":
        verify_artifact(LOCAL_BINARY)
    else:
        device_tests(args.device, args.team, args.scheme, args.iterations, args.jobs)


if __name__ == "__main__":
    main()
