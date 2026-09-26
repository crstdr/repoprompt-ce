#!/usr/bin/env python3
"""Hermetic tests for the ./conductor bash wrapper's SDKROOT pinning.

/usr/bin/python3 is an xcrun shim that injects SDKROOT=<default SDK> into python3 when SDKROOT is
unset. With newer Command Line Tools than the selected Xcode (for example CLT 27 next to Xcode 26.5)
that default SDK does not match the compiler, and every conductor job inherited it through the
BUILD_ENV_KEYS passthrough. The wrapper pins the selected Xcode's macOS SDK before python3 runs.
These tests run the real wrapper with a fake python3 and a fake xcrun on PATH.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WRAPPER = REPO_ROOT / "conductor"

FAKE_PYTHON3 = """#!/bin/sh
printf 'SDKROOT=%s\\n' "${SDKROOT-__UNSET__}"
for argument in "$@"; do printf 'ARG=%s\\n' "$argument"; done
"""

FAKE_XCODE_SELECT = """#!/bin/sh
printf '%s\\n' "$FAKE_XCODE_SELECT_PATH"
"""

FAKE_XCRUN = """#!/bin/sh
printf '%s|DEVELOPER_DIR=%s\\n' "$*" "${DEVELOPER_DIR-}" >> "$FAKE_XCRUN_LOG"
if [ "$*" = "--sdk macosx --show-sdk-version" ]; then
    printf '%s\\n' "${FAKE_XCRUN_SDK_VERSION:-26.5}"
    exit 0
fi
case "${FAKE_XCRUN_MODE:-ok}" in
    fail) echo "xcrun: error: simulated lookup failure" >&2; exit 1 ;;
    empty) echo "xcrun: warning: simulated empty lookup" >&2; exit 0 ;;
    *) printf '%s\\n' "$FAKE_XCRUN_SDK" ;;
esac
"""


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class ConductorWrapperSDKRootTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = Path(tempfile.mkdtemp(prefix="conductor-wrapper-test-"))
        self.bin = self.scratch / "bin"
        self.bin.mkdir()
        write_executable(self.bin / "python3", FAKE_PYTHON3)
        write_executable(self.bin / "xcrun", FAKE_XCRUN)
        write_executable(self.bin / "xcode-select", FAKE_XCODE_SELECT)
        self.xcode_developer_dir = self.scratch / "Xcode.app/Contents/Developer"
        (self.xcode_developer_dir / "usr/bin").mkdir(parents=True)
        write_executable(self.xcode_developer_dir / "usr/bin/xcodebuild", "#!/bin/sh\n")
        self.clt_developer_dir = self.scratch / "CommandLineTools"
        (self.clt_developer_dir / "usr/bin").mkdir(parents=True)
        self.sdk = self.xcode_developer_dir / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
        self.sdk.mkdir(parents=True)
        self.xcrun_log = self.scratch / "xcrun.log"

    def tearDown(self) -> None:
        shutil.rmtree(self.scratch, ignore_errors=True)

    def run_wrapper(self, extra_env: dict[str, str], path: str | None = None) -> tuple[str | None, str]:
        env = {
            "PATH": path or f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.scratch),
            "FAKE_XCRUN_LOG": str(self.xcrun_log),
            "FAKE_XCRUN_SDK": str(self.sdk),
            "FAKE_XCODE_SELECT_PATH": str(self.xcode_developer_dir),
        }
        env.update(extra_env)
        result = subprocess.run(
            [str(WRAPPER), "status", "--label", "a b"], env=env, capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = [line.removeprefix("ARG=") for line in result.stdout.splitlines() if line.startswith("ARG=")]
        self.assertEqual(arguments[1:], ["status", "--label", "a b"], "wrapper must forward its arguments")
        lines = [line for line in result.stdout.splitlines() if line.startswith("SDKROOT=")]
        self.assertEqual(len(lines), 1, result.stdout)
        value = lines[0].removeprefix("SDKROOT=")
        return (None if value == "__UNSET__" else value), result.stderr

    def xcrun_calls(self) -> list[str]:
        """SDK-path lookups made by the wrapper (the resolver's version probes are excluded)."""
        calls = self.xcrun_log.read_text().splitlines() if self.xcrun_log.exists() else []
        return [call for call in calls if call.split("|")[0] == "--sdk macosx --show-sdk-path"]

    def test_unset_sdkroot_is_pinned_to_the_selected_xcode_sdk(self) -> None:
        sdkroot, stderr = self.run_wrapper({})
        self.assertEqual(sdkroot, str(self.sdk))
        self.assertEqual(stderr, "")
        self.assertEqual([call.split("|")[0] for call in self.xcrun_calls()], ["--sdk macosx --show-sdk-path"])

    def test_empty_sdkroot_is_treated_as_unset(self) -> None:
        sdkroot, _ = self.run_wrapper({"SDKROOT": ""})
        self.assertEqual(sdkroot, str(self.sdk))

    def test_user_set_sdkroot_is_never_overridden(self) -> None:
        user_sdk = str(self.scratch / "user-chosen.sdk")
        sdkroot, stderr = self.run_wrapper({"SDKROOT": user_sdk})
        self.assertEqual(sdkroot, user_sdk)
        self.assertEqual(stderr, "")
        self.assertEqual(self.xcrun_calls(), [], "xcrun must not run when SDKROOT is already set")

    def test_developer_dir_drives_the_lookup(self) -> None:
        developer_dir = str(self.xcode_developer_dir)
        sdkroot, _ = self.run_wrapper({"DEVELOPER_DIR": developer_dir, "FAKE_XCODE_SELECT_PATH": str(self.clt_developer_dir)})
        self.assertEqual(sdkroot, str(self.sdk))
        self.assertEqual(self.xcrun_calls(), [f"--sdk macosx --show-sdk-path|DEVELOPER_DIR={developer_dir}"])

    def test_command_line_tools_selection_leaves_sdkroot_unset(self) -> None:
        # With only the Command Line Tools selected, a later full-Xcode resolution (for example
        # install_local_production.sh) must not inherit a pinned CLT SDK: keep the old behaviour.
        for extra in ({"FAKE_XCODE_SELECT_PATH": str(self.clt_developer_dir)}, {"DEVELOPER_DIR": str(self.clt_developer_dir)}):
            with self.subTest(extra=extra):
                sdkroot, stderr = self.run_wrapper(extra)
                self.assertIsNone(sdkroot)
                self.assertEqual(stderr, "")
        self.assertEqual(self.xcrun_calls(), [], "xcrun must not run without a full Xcode selected")

    def test_xcode_the_installer_would_reject_is_not_pinned(self) -> None:
        # resolve_full_xcode_developer_dir.sh rejects a selected Xcode whose macOS SDK is older than
        # its minimum and falls back to another Xcode; pinning the selected Xcode's SDK would then
        # hand install_local_production.sh a mismatched SDKROOT.
        sdkroot, stderr = self.run_wrapper({"FAKE_XCRUN_SDK_VERSION": "15.4"})
        self.assertIsNone(sdkroot)
        self.assertEqual(stderr, "")
        self.assertEqual(self.xcrun_calls(), [], "no SDK pin when the installer would choose another Xcode")

    def test_failed_empty_or_missing_lookup_leaves_sdkroot_unset_silently(self) -> None:
        for mode, sdk in (("fail", str(self.sdk)), ("empty", str(self.sdk)), ("ok", str(self.scratch / "missing.sdk"))):
            with self.subTest(mode=mode, sdk=sdk):
                sdkroot, stderr = self.run_wrapper({"FAKE_XCRUN_MODE": mode, "FAKE_XCRUN_SDK": sdk})
                self.assertIsNone(sdkroot)
                self.assertEqual(stderr, "")

    def test_missing_xcrun_leaves_sdkroot_unset_silently(self) -> None:
        no_xcrun_bin = self.scratch / "no-xcrun-bin"
        no_xcrun_bin.mkdir()
        write_executable(no_xcrun_bin / "python3", FAKE_PYTHON3)
        dirname = shutil.which("dirname")
        self.assertIsNotNone(dirname)
        os.symlink(dirname, no_xcrun_bin / "dirname")
        sdkroot, stderr = self.run_wrapper({}, path=f"{no_xcrun_bin}:/bin")
        self.assertIsNone(sdkroot)
        self.assertEqual(stderr, "")


if __name__ == "__main__":
    unittest.main()
