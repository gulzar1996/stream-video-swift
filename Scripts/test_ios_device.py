#!/usr/bin/env python3
"""Run repository SDK suites in a signed host on a physical iOS device."""

import argparse
import json
from pathlib import Path
import subprocess

from webrtc import ROOT, WORK, run


def project_spec(suite="StreamVideoTests"):
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-",
        str(ROOT / "StreamVideo.xcodeproj/project.pbxproj")
    ], text=True))["objects"]
    host = "StreamSDKDeviceHost"
    spec = {
        "name": "StreamSDKDeviceTests",
        "options": {"deploymentTarget": {"iOS": "15.0"}},
        "settings": {"base": {"CODE_SIGN_STYLE": "Automatic",
                                "SWIFT_VERSION": "6.0",
                                "SWIFT_STRICT_CONCURRENCY": "complete"}},
        "packages": {
            "StreamVideo": {"path": str(ROOT)},
            "StreamSwiftTestHelpers": {
                "url": "https://github.com/GetStream/stream-chat-swift-test-helpers",
                "exactVersion": "0.3.5"
            }
        },
        "targets": {
            host: {
                "type": "application", "platform": "iOS",
                "sources": [str(ROOT / "TestTools/VideoUpscaling/Host")],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "io.getstream.local.SDKDeviceHost",
                    "INFOPLIST_FILE": str(ROOT / "TestTools/VideoUpscaling/Host/Info.plist"),
                    "TARGETED_DEVICE_FAMILY": "1,2"
                }}
            }
        },
        "schemes": {}
    }
    for name in (suite,):
        identifier, target = next((key, item) for key, item in project.items()
                                  if item.get("isa") == "PBXNativeTarget" and
                                  item.get("name") == name)
        sources = [str(ROOT / "TestTools/VideoUpscaling/SDK")]
        owned = target.get("fileSystemSynchronizedGroups", [])
        for key, group in project.items():
            if group.get("isa") != "PBXFileSystemSynchronizedRootGroup":
                continue
            exceptions = [project[value] for value in group.get("exceptions", [])
                          if project[value].get("target") == identifier]
            members = [member for exception in exceptions
                       for member in exception.get("membershipExceptions", [])]
            directory = ROOT / group["path"]
            if key in owned:
                sources.append({"path": str(directory), "excludes": members})
            else:
                sources.extend({"path": str(directory / member)} for member in members
                               if (directory / member).exists())
        product = name.removesuffix("Tests")
        spec["targets"][name] = {
            "type": "bundle.unit-test", "platform": "iOS",
            "sources": sources,
            "dependencies": [
                {"target": host},
                {"package": "StreamVideo", "product": product},
                {"package": "StreamSwiftTestHelpers"}
            ],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": f"io.getstream.local.{name}",
                "GENERATE_INFOPLIST_FILE": "YES",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG STREAM_TESTS"
            }}
        }
        plan = json.loads((ROOT / name / f"{product}.xctestplan").read_text())
        skipped = plan["testTargets"][0].get("skippedTests", [])
        spec["schemes"][name] = {
            "build": {"targets": {host: "all", name: ["test"]}},
            "test": {"targets": [{"name": name, "skippedTests": skipped}]}
        }
    return spec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--suite", choices=["StreamVideoTests", "StreamVideoSwiftUITests"],
                        default="StreamVideoTests")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--skip", action="append", default=[])
    parser.add_argument("--iterations", type=int, default=1)
    args = parser.parse_args()
    directory = WORK / "sdk-device-tests"
    directory.mkdir(parents=True, exist_ok=True)
    spec = directory / "project.json"
    spec.write_text(json.dumps(project_spec(args.suite), indent=2))
    run(["xcodegen", "generate", "--spec", spec, "--project", directory])
    import datetime
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    command = ["xcodebuild", "test", "-project", directory / "StreamSDKDeviceTests.xcodeproj",
               "-scheme", args.suite, "-destination", f"platform=iOS,id={args.device}",
               "-derivedDataPath", directory / "DerivedData",
               "-resultBundlePath", directory / f"{args.suite}-{stamp}.xcresult",
               f"DEVELOPMENT_TEAM={args.team}", "-parallel-testing-enabled", "NO",
               "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG STREAM_TESTS"]
    command.extend(f"-only-testing:{args.suite}/{name}" for name in args.only)
    command.extend(f"-skip-testing:{args.suite}/{name}" for name in args.skip)
    if args.iterations > 1:
        command.extend(["-test-iterations", str(args.iterations), "-run-tests-until-failure"])
    run(command)


if __name__ == "__main__":
    main()
