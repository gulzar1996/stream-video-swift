import importlib.util
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("device_runner", SCRIPTS / "test_ios_device.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


class DeviceProjectTests(unittest.TestCase):
    def test_swiftui_includes_shared_resource_membership(self):
        project = subject.project_spec("StreamVideoSwiftUITests")
        sources = project["targets"]["StreamVideoSwiftUITests"]["sources"]
        paths = {entry["path"] for entry in sources if isinstance(entry, dict)}
        self.assertIn(str(subject.ROOT /
            "StreamVideoSwiftUITests/CallView/LayoutComponents/mock-profile-image.jpg"), paths)
        self.assertIn(str(subject.ROOT / "StreamVideoSwiftUITests/Assets.xcassets"), paths)

    def test_explicit_exclusions_are_forwarded_to_xcodebuild(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(subject, "WORK", Path(temporary)), \
             patch.object(subject, "project_spec", return_value={}), \
             patch.object(subject, "run") as run, \
             patch("sys.argv", ["runner", "--device", "local", "--team", "local",
                                "--skip", "SnapshotTests/test_picture"]):
            subject.main()
            self.assertIn("-skip-testing:StreamVideoTests/SnapshotTests/test_picture",
                          run.call_args.args[0])

    def test_project_includes_only_selected_suite_to_avoid_duplicate_file_groups(self):
        for suite in ("StreamVideoTests", "StreamVideoSwiftUITests"):
            with self.subTest(suite=suite):
                project = subject.project_spec(suite)
                self.assertEqual(set(project["targets"]), {"StreamSDKDeviceHost", suite})
                self.assertEqual(set(project["schemes"]), {suite})


if __name__ == "__main__":
    unittest.main()
