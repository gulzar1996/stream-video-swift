import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "webrtc.py"
spec = importlib.util.spec_from_file_location("webrtc_build", SCRIPT)
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)


class NativePatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        self.patches = self.root / "patches"
        self.patches.mkdir()
        (self.source / "frame.txt").write_text("original\n")
        (self.patches / "001-frame.patch").write_text(
            "diff --git a/frame.txt b/frame.txt\n"
            "--- a/frame.txt\n+++ b/frame.txt\n"
            "@@ -1 +1 @@\n-original\n+processed\n"
        )

    def test_applies_patch_without_changing_unrelated_edits(self):
        unrelated = self.source / "local.txt"
        unrelated.write_text("keep my work\n")
        subject.apply_patches(self.source, self.patches)
        self.assertEqual((self.source / "frame.txt").read_text(), "processed\n")
        self.assertEqual(unrelated.read_text(), "keep my work\n")

    def test_repeated_application_is_idempotent(self):
        (self.source / "frame.txt").write_text("processed\n")
        subject.apply_patches(self.source, self.patches)
        self.assertEqual((self.source / "frame.txt").read_text(), "processed\n")

    def test_conflicting_edit_is_rejected_and_preserved(self):
        (self.source / "frame.txt").write_text("local change\n")
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            subject.apply_patches(self.source, self.patches)
        self.assertEqual((self.source / "frame.txt").read_text(), "local change\n")

    def test_conflict_in_later_patch_does_not_partially_apply(self):
        (self.patches / "002-missing.patch").write_text(
            "diff --git a/missing.txt b/missing.txt\n"
            "--- a/missing.txt\n+++ b/missing.txt\n"
            "@@ -1 +1 @@\n-old\n+new\n"
        )
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            subject.apply_patches(self.source, self.patches)
        self.assertEqual((self.source / "frame.txt").read_text(), "original\n")

    def test_applied_patch_and_new_independent_patch(self):
        (self.source / "frame.txt").write_text("processed\n")
        (self.source / "other.txt").write_text("old\n")
        (self.patches / "002-other.patch").write_text(
            "diff --git a/other.txt b/other.txt\n"
            "--- a/other.txt\n+++ b/other.txt\n"
            "@@ -1 +1 @@\n-old\n+new\n"
        )
        subject.apply_patches(self.source, self.patches)
        self.assertEqual((self.source / "frame.txt").read_text(), "processed\n")
        self.assertEqual((self.source / "other.txt").read_text(), "new\n")


class NativeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.overlay = root / "overlay"
        self.destination = root / "destination"
        self.record = root / "installed.json"
        self.overlay.mkdir()
        self.destination.mkdir()
        (self.overlay / "engine.mm").write_text("first version\n")

    def test_installs_native_test_sources(self):
        (self.overlay / "source_tests.cc").write_text("test source")
        subject.synchronize_overlay(self.overlay, self.destination, self.record)
        self.assertTrue((self.destination / "source_tests.cc").is_file())

    def test_installs_owned_sources(self):
        subject.synchronize_overlay(self.overlay, self.destination, self.record)
        self.assertTrue((self.destination / "engine.mm").is_file())
        self.assertEqual((self.destination / "engine.mm").read_text(), "first version\n")

    def test_updates_unchanged_previous_installation(self):
        subject.synchronize_overlay(self.overlay, self.destination, self.record)
        (self.overlay / "engine.mm").write_text("second version\n")
        subject.synchronize_overlay(self.overlay, self.destination, self.record)
        self.assertTrue((self.destination / "engine.mm").is_file())
        self.assertEqual((self.destination / "engine.mm").read_text(), "second version\n")

    def test_native_edit_is_preserved_and_rejected(self):
        subject.synchronize_overlay(self.overlay, self.destination, self.record)
        (self.destination / "engine.mm").write_text("native edit\n")
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            subject.synchronize_overlay(self.overlay, self.destination, self.record)
        self.assertEqual((self.destination / "engine.mm").read_text(), "native edit\n")

    def test_conflict_is_checked_before_copying_other_files(self):
        (self.destination / "engine.mm").write_text("native edit\n")
        (self.overlay / "another.h").write_text("new header\n")
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            subject.synchronize_overlay(self.overlay, self.destination, self.record)
        self.assertFalse((self.destination / "another.h").exists())
        self.assertFalse(self.record.exists())


class CheckoutTests(unittest.TestCase):
    def test_wrong_revision_is_rejected_before_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            local = root / "local.txt"
            local.write_text("keep")
            with patch.object(subject.subprocess, "check_output", return_value="wrong\n"):
                with self.assertRaisesRegex(RuntimeError, "revision"):
                    subject.verify_checkout(root, "pinned")
            self.assertEqual(local.read_text(), "keep")

    def test_matching_revision_preserves_dirty_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            local = root / "local.txt"
            local.write_text("keep")
            with patch.object(subject.subprocess, "check_output", return_value="pinned\n"):
                subject.verify_checkout(root, "pinned")
            self.assertEqual(local.read_text(), "keep")

    def test_symlink_checkout_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "real").mkdir()
            (root / "link").symlink_to(root / "real")
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                subject.verify_checkout(root / "link", "pinned")


class SetupTests(unittest.TestCase):
    def test_make_keeps_public_https_repository(self):
        with patch.object(subject, "run") as run:
            subject.make("deps")
        self.assertIn(f"WEBRTC_REPO={subject.NATIVE_URL}", run.call_args.args[0])

    def test_setup_uses_forks_public_hook_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "src"
            depot = root / "depot"
            source.mkdir()
            depot.mkdir()
            with patch.object(subject, "WORK", root), \
                 patch.object(subject, "SOURCE", source), \
                 patch.object(subject, "DEPOT", depot), \
                 patch.object(subject, "verify_checkout"), \
                 patch.object(subject, "make") as make:
                subject.setup()
            self.assertEqual([call.args[0] for call in make.call_args_list],
                             ["bootstrap", "deps", "runhooks"])


if __name__ == "__main__":
    unittest.main()
