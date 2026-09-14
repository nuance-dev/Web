"""Validate signed app capabilities without exposing signing-account metadata."""
from pathlib import Path
import plistlib
import subprocess


class EntitlementError(Exception):
    pass


def validate_entitlements(actual, expected):
    if not isinstance(expected, dict) or not isinstance(actual, dict):
        raise EntitlementError('The signed app or repository has no readable entitlements dictionary.')
    baseline = ['com.apple.security.app-sandbox', 'com.apple.security.network.client']
    if any(expected.get(key) is not True for key in baseline):
        raise EntitlementError('Repository entitlements must require sandboxing and outbound networking.')
    forbidden = ['get-task-allow', 'com.apple.security.get-task-allow',
                 'com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory']
    if any(actual.get(key) not in (None, False) for key in forbidden):
        raise EntitlementError('The signed app grants a forbidden debug or executable-memory entitlement.')
    for key, value in expected.items():
        granted = actual.get(key)
        if value is True and granted is not True:
            raise EntitlementError('The signed app is missing a required repository entitlement.')
        if value is False and granted not in (None, False):
            raise EntitlementError('The signed app enables an entitlement disabled by the repository.')
        if not isinstance(value, bool) and granted != value:
            raise EntitlementError('The signed app entitlements do not match the repository.')
    # Export may add signing identifiers, but it must not broaden security grants.
    if any(key.startswith('com.apple.security.') and key not in expected and value not in (None, False)
           for key, value in actual.items()):
        raise EntitlementError('The signed app grants an unreviewed security entitlement.')


def verify_signed_entitlements(app, source):
    try:
        expected = plistlib.loads(Path(source).read_bytes())
    except (OSError, plistlib.InvalidFileException):
        raise EntitlementError('Repository entitlements are missing or invalid; run from the Web repository.') from None
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True)
    if result.returncode:
        raise EntitlementError('Could not inspect the app signed entitlements.')
    try:
        actual = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        raise EntitlementError('The signed app has no readable entitlements; submission or packaging was stopped.') from None
    validate_entitlements(actual, expected)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--entitlements', type=Path,
                        default=Path(__file__).resolve().parent.parent / 'Web/Web.entitlements')
    args = parser.parse_args()
    try:
        verify_signed_entitlements(args.app, args.entitlements)
    except EntitlementError as error:
        raise SystemExit(str(error)) from None
    print('Signed entitlements match the repository policy.')
