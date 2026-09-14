import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from release_entitlements import EntitlementError, validate_entitlements, verify_signed_entitlements

spec = importlib.util.spec_from_file_location('package_notarized', SCRIPTS / 'package-notarized.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class ReleaseEntitlementTests(unittest.TestCase):
    def setUp(self):
        self.expected = plistlib.loads((SCRIPTS.parent / 'Web/Web.entitlements').read_bytes())

    def test_export_can_omit_false_values_and_add_signing_identifiers(self):
        actual = {key: value for key, value in self.expected.items() if value is True}
        actual['com.apple.developer.team-identifier'] = 'SYNTHETIC'
        validate_entitlements(actual, self.expected)

    def test_each_required_capability_must_be_signed(self):
        for key, value in self.expected.items():
            if value is not True:
                continue
            with self.subTest(key=key):
                actual = dict(self.expected)
                actual.pop(key)
                with self.assertRaises(EntitlementError):
                    validate_entitlements(actual, self.expected)

    def test_sandbox_cannot_be_removed_from_source_policy(self):
        changed = dict(self.expected)
        changed.pop('com.apple.security.app-sandbox')
        with self.assertRaises(EntitlementError):
            validate_entitlements(changed, changed)

    def test_disabled_permissions_cannot_be_enabled(self):
        for key, value in self.expected.items():
            if value is not False:
                continue
            with self.subTest(key=key):
                actual = dict(self.expected, **{key: True})
                with self.assertRaises(EntitlementError):
                    validate_entitlements(actual, self.expected)

    def test_debug_and_jit_are_rejected_even_if_source_accidentally_enables_them(self):
        for key in ['get-task-allow', 'com.apple.security.get-task-allow',
                    'com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory']:
            with self.subTest(key=key):
                changed = dict(self.expected, **{key: True})
                with self.assertRaises(EntitlementError):
                    validate_entitlements(changed, changed)

    def test_export_cannot_add_an_unreviewed_security_grant(self):
        actual = dict(self.expected, **{'com.apple.security.cs.disable-library-validation': True})
        with self.assertRaises(EntitlementError):
            validate_entitlements(actual, self.expected)

    def test_inspection_rejects_empty_signed_entitlements_without_exposing_tool_output(self):
        result = subprocess.CompletedProcess([], 0, stdout=b'', stderr=b'PRIVATE_TOOL_OUTPUT')
        with patch('release_entitlements.subprocess.run', return_value=result):
            with self.assertRaises(EntitlementError) as error:
                verify_signed_entitlements(Path('Fixture.app'), SCRIPTS.parent / 'Web/Web.entitlements')
        self.assertNotIn('PRIVATE_TOOL_OUTPUT', str(error.exception))


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'Web.app'
        self.resources = self.app / 'Contents/Resources'
        self.resources.mkdir(parents=True)
        self.notices = self.root / 'source-notices.txt'
        self.notices.write_text('Fixture license text\n')
        self.bundled = self.resources / 'ThirdPartyNotices.txt'
        self.bundled.write_bytes(self.notices.read_bytes())

    def test_matching_notice_is_accepted(self):
        package.verify_bundle_contents(self.app, self.notices)

    def test_missing_changed_or_duplicate_notices_are_rejected(self):
        self.bundled.unlink()
        with self.assertRaises(package.PackageError):
            package.verify_bundle_contents(self.app, self.notices)
        self.bundled.write_text('Stale notice')
        with self.assertRaises(package.PackageError):
            package.verify_bundle_contents(self.app, self.notices)
        self.bundled.write_bytes(self.notices.read_bytes())
        (self.app / 'ThirdPartyNotices.txt').write_bytes(self.notices.read_bytes())
        with self.assertRaises(package.PackageError):
            package.verify_bundle_contents(self.app, self.notices)

    def test_account_paths_in_resources_are_rejected_in_utf8_and_utf16(self):
        resource = self.resources / 'fixture.bin'
        for prefix in ['/Users/', '/home/']:
            for encoding in ['utf-8', 'utf-16le', 'utf-16be']:
                with self.subTest(prefix=prefix, encoding=encoding):
                    resource.write_bytes((prefix + 'fixture/source.swift').encode(encoding))
                    with self.assertRaises(package.PackageError):
                        package.verify_bundle_contents(self.app, self.notices)

    def test_symlink_outside_bundle_is_rejected(self):
        external = self.root / 'outside.txt'
        external.write_text('Fixture')
        (self.resources / 'outside.txt').symlink_to(external)
        with self.assertRaises(package.PackageError):
            package.verify_bundle_contents(self.app, self.notices)

    def test_archive_check_never_creates_a_distribution_package(self):
        with patch.object(sys, 'argv', ['package-notarized.py', str(self.app), '--check-archive']), \
             patch.object(package, 'verify', return_value='1.2.3') as verify, \
             patch.object(package.tempfile, 'TemporaryDirectory') as staging, \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            package.main()
        self.assertFalse(verify.call_args.kwargs['distribution'])
        staging.assert_not_called()
        self.assertNotIn('ready_to_package', output.getvalue())


if __name__ == '__main__':
    unittest.main()
