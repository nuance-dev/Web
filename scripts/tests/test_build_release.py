"""Exercise the local build script's signing boundary without developer credentials."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


BUILD_SCRIPT = Path(__file__).resolve().parents[1] / "build-release.sh"


class LocalBuildSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="web-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "Web").mkdir()
        shutil.copyfile(BUILD_SCRIPT, self.root / "scripts/build-release.sh")
        (self.root / "Web/Web.entitlements").write_text("<plist><dict/></plist>")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        driver = self.bin / "driver"
        driver.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "tool = pathlib.Path(sys.argv[0]).name\n"
            "with open(os.environ['WEB_TEST_COMMAND_LOG'], 'a') as output:\n"
            "    output.write(json.dumps([tool, *sys.argv[1:]]) + '\\n')\n"
            "if tool == 'xcodebuild':\n"
            "    if os.environ.get('WEB_TEST_BUILD_FAILURE'):\n"
            "        sys.exit(65)\n"
            "    binary = pathlib.Path(os.environ['WEB_BUILD_DIR']) / 'Build/Products/Release/Web.app/Contents/MacOS/Web'\n"
            "    binary.parent.mkdir(parents=True)\n"
            "    binary.write_text(os.environ.get('WEB_TEST_BINARY_CONTENT', 'stripped-executable'))\n"
        )
        driver.chmod(0o755)
        for tool in ["xcodebuild", "xcrun", "codesign"]:
            (self.bin / tool).symlink_to(driver)
        self.environment = dict(os.environ)
        self.environment.pop("WEB_SIGNING_IDENTITY", None)
        self.environment.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            WEB_BUILD_DIR=str(self.root / "output"),
            WEB_TEST_COMMAND_LOG=str(self.log),
        )

    def run_build(self):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/build-release.sh")],
            env=self.environment, text=True, capture_output=True,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_default_build_never_selects_a_developer_identity(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual([command[0] for command in commands],
                         ["xcodebuild", "xcrun", "codesign", "codesign"])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", commands[0])
        signing = commands[2]
        self.assertEqual(signing[signing.index("--sign") + 1], "-")
        self.assertIn("--verify", commands[3])
        self.assertIn("local use", result.stdout)
        self.assertIn("notarization", result.stdout)

    def test_explicit_signing_override_is_used(self):
        self.environment["WEB_SIGNING_IDENTITY"] = "test-certificate-fingerprint"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = self.commands()[2]
        self.assertEqual(signing[signing.index("--sign") + 1],
                         "test-certificate-fingerprint")

    def test_source_path_in_executable_stops_before_signing_without_echoing_it(self):
        source_path = "/" + "Users/build-account/private-project/source.swift"
        self.environment["WEB_TEST_BINARY_CONTENT"] = source_path
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("codesign", [command[0] for command in self.commands()])
        self.assertNotIn(source_path, result.stdout + result.stderr)
        self.assertIn("Refusing to sign", result.stderr)

    def test_failed_build_never_strips_or_signs_an_old_product(self):
        self.environment["WEB_TEST_BUILD_FAILURE"] = "1"
        result = self.run_build()
        self.assertEqual(result.returncode, 65)
        self.assertEqual([command[0] for command in self.commands()], ["xcodebuild"])


if __name__ == "__main__":
    unittest.main()
