#!/usr/bin/env python3
"""Package an already signed and notarized Web.app. No credentials or uploads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

from release_entitlements import EntitlementError, verify_signed_entitlements


REPO_ROOT = Path(__file__).resolve().parent.parent


class PackageError(Exception):
    pass


def run(args, message):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise PackageError(message)
    return result.stdout + result.stderr


def verify_bundle_contents(app, notices):
    try:
        expected = notices.read_bytes()
    except OSError:
        raise PackageError('The source third-party notices are missing.') from None
    bundled = list(app.rglob('ThirdPartyNotices.txt'))
    if len(bundled) != 1 or bundled[0].read_bytes() != expected:
        raise PackageError('Bundled third-party notices are missing or differ from source.')
    markers = [value.encode(encoding) for value in ['/Users/', '/home/']
               for encoding in ['utf-8', 'utf-16le', 'utf-16be']]
    for path in app.rglob('*'):
        if path.is_symlink():
            if any(marker in os.fsencode(os.readlink(path)) for marker in markers):
                raise PackageError('The app contains a local account path in a symlink.')
            if not path.resolve().is_relative_to(app.resolve()):
                raise PackageError('The app contains a symlink outside its bundle.')
            continue
        if path.is_file():
            if path.name == '.DS_Store':
                raise PackageError('The app contains incidental filesystem metadata.')
            if any(marker in path.read_bytes() for marker in markers):
                raise PackageError('The app contains a local account path; submission or packaging was stopped.')


def verify(app, entitlements=REPO_ROOT / 'Web/Web.entitlements',
           notices=REPO_ROOT / 'Web/Resources/ThirdPartyNotices.txt', distribution=True):
    if app.name != 'Web.app' or not app.is_dir():
        raise PackageError('Expected a Web.app bundle.')
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    except (OSError, plistlib.InvalidFileException):
        raise PackageError('The app Info.plist could not be read.') from None
    version = info.get('CFBundleShortVersionString', '')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise PackageError('The app has no valid release version.')
    verify_bundle_contents(app, notices)
    main = app / 'Contents/MacOS/Web'
    architectures = run(['lipo', '-archs', str(main)], 'Could not inspect architecture.').decode().strip()
    if architectures != 'arm64':
        raise PackageError('This package expects an Apple Silicon-only build.')
    detail = run(['codesign', '-dv', '--verbose=4', str(app)], 'The app has no readable signature.').decode(errors='replace')
    if distribution and 'Authority=Developer ID Application:' not in detail:
        raise PackageError('Developer ID Application signing is required; local development signing is insufficient.')
    if distribution and ('(runtime)' not in detail or not re.search(r'^Timestamp=.+$', detail, re.M)):
        raise PackageError('Hardened runtime and a secure signing timestamp are required.')
    run(['codesign', '--verify', '--deep', '--strict', str(app)], 'Signature verification failed.')
    verify_signed_entitlements(app, entitlements)
    if distribution:
        run(['xcrun', 'stapler', 'validate', str(app)], 'The notarization ticket is missing or invalid.')
        run(['spctl', '--assess', '--type', 'execute', str(app)], 'Gatekeeper did not accept the app.')
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, default=REPO_ROOT / 'dist')
    parser.add_argument('--entitlements', type=Path, default=REPO_ROOT / 'Web/Web.entitlements')
    parser.add_argument('--notices', type=Path, default=REPO_ROOT / 'Web/Resources/ThirdPartyNotices.txt')
    checks = parser.add_mutually_exclusive_group()
    checks.add_argument('--check', action='store_true', help='Verify notarized distribution without packaging.')
    checks.add_argument('--check-archive', action='store_true', help='Check an archive before Apple submission; never package it.')
    args = parser.parse_args()
    app = args.app.resolve()
    version = verify(app, args.entitlements, args.notices, distribution=not args.check_archive)
    if args.check or args.check_archive:
        print(json.dumps({'archive_checks_passed': True, 'version': version} if args.check_archive else
                         {'ready_to_package': True, 'version': version, 'architecture': 'arm64'}))
        return
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / f'Web-{version}-arm64.zip'
    checksum = args.output / f'Web-{version}-arm64.zip.sha256'
    if destination.exists() or checksum.exists():
        raise PackageError('A package with this version already exists; inspect it before replacing it.')
    with tempfile.TemporaryDirectory(prefix='.web-package-', dir=args.output) as directory:
        staging = Path(directory) / 'Web.app'
        run(['ditto', '--noextattr', '--norsrc', '--noqtn', '--noacl', str(app), str(staging)], 'Could not stage the app.')
        verify(staging, args.entitlements, args.notices)
        archive = Path(directory) / destination.name
        run(['ditto', '-c', '-k', '--keepParent', '--noextattr', '--norsrc', '--noqtn', '--noacl', str(staging), str(archive)], 'Could not create the ZIP.')
        with zipfile.ZipFile(archive) as zipped:
            names = zipped.namelist()
            if not names or any(not n.startswith('Web.app/') or '..' in Path(n).parts for n in names):
                raise PackageError('The ZIP contains unexpected paths.')
            if any('/.DS_Store' in n or n.startswith('__MACOSX/') for n in names):
                raise PackageError('The ZIP contains incidental filesystem metadata.')
        extracted = Path(directory) / 'extracted'
        run(['ditto', '-x', '-k', str(archive), str(extracted)], 'Could not verify the ZIP round trip.')
        verify(extracted / 'Web.app', args.entitlements, args.notices)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        # Linking is exclusive: a parallel run cannot overwrite a reviewed package.
        try:
            os.link(archive, destination)
        except OSError:
            raise PackageError('Could not safely place the final ZIP.') from None
        checksum.write_text(f'{digest}  {destination.name}\n')
    print(json.dumps({'asset': destination.name, 'version': version, 'architecture': 'arm64', 'sha256': digest}))


if __name__ == '__main__':
    try:
        main()
    except (PackageError, EntitlementError) as error:
        raise SystemExit(str(error)) from None
