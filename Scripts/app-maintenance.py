#!/usr/bin/env python3
"""Local certificate signing and verified, recoverable app updates. No TCC edits."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / '.glasssnap-signing.local.json'
TARGET = Path('/Applications/GlassSnap.app')
BUILD = ROOT / 'build/GlassSnap.app'


def run(args, *, capture=False, env=None):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, text=True)
    if result.returncode:
        # Never include argv: setup commands can carry a temporary PKCS#12 password.
        detail = (result.stderr or '').strip() if capture else ''
        raise RuntimeError(f'{Path(str(args[0])).name} failed ({result.returncode}). {detail}')
    return result.stdout.strip() if capture else ''


def info(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)


def build_info():
    path = ROOT / 'Resources/Info.local.plist'
    if not path.exists():
        path = ROOT / 'Resources/Info.plist'
    with path.open('rb') as stream:
        return plistlib.load(stream)


def configuration():
    if not CONFIG.exists():
        raise RuntimeError('Stable signing is not configured. Run ./Scripts/setup-signing.sh first. '
                           'For a disposable unsigned-identity build only, use ./Scripts/build.sh --adhoc.')
    data = json.loads(CONFIG.read_text())
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', data.get('identity_sha1', '')):
        raise RuntimeError('Invalid signing fingerprint in local configuration.')
    if not re.fullmatch(r'[A-Za-z0-9.-]+', data.get('bundle_identifier', '')):
        raise RuntimeError('Invalid bundle identifier in local configuration.')
    if build_info()['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Bundle identity changed. Restore the local plist; do not reset permissions or replace the signing identity.')
    if not Path(data['keychain']).is_file():
        raise RuntimeError('The configured keychain is unavailable. Restore it; do not generate another identity.')
    return data


def requirement(data):
    # Pin both the app identifier and the actual certificate, never just a name.
    return f'identifier "{data["bundle_identifier"]}" and certificate leaf = H"{data["identity_sha1"]}"'


def verify(app, data):
    if info(app)['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Application bundle identifier does not match the saved signing identity.')
    run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement(data), app], capture=True)


def sign(app):
    data = configuration()
    if info(app)['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Refusing to sign a bundle with a different identifier.')
    run(['/usr/bin/codesign', '--force', '--sign', data['identity_sha1'], '--keychain', data['keychain'],
         '--timestamp=none', '--identifier', data['bundle_identifier'],
         '--requirements', '=designated => ' + requirement(data), app])
    verify(app, data)


def setup(identity=None):
    if CONFIG.exists():
        configuration()
        print('Stable signing is already configured. Keeping the existing identity.')
        return
    bundle_id = build_info()['CFBundleIdentifier']
    if TARGET.exists() and info(TARGET)['CFBundleIdentifier'] != bundle_id:
        raise RuntimeError('The installed app has a different bundle identifier. Preserve it in Resources/Info.local.plist before setup.')
    if not re.fullmatch(r'[A-Za-z0-9.-]+', bundle_id):
        raise RuntimeError('Unsupported bundle identifier.')
    keychain = run(['/usr/bin/security', 'default-keychain', '-d', 'user'], capture=True).strip('"')
    if identity:
        if not re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
            raise RuntimeError('--identity must be the exact 40-character certificate fingerprint, not an ambiguous display name.')
        fingerprint = identity.upper()
    else:
        label = 'GlassSnap Local Development'
        existing = subprocess.run(['/usr/bin/security', 'find-certificate', '-c', label, keychain],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if existing.returncode == 0:
            raise RuntimeError('A GlassSnap certificate already exists. Recover its fingerprint with --identity; do not create a replacement.')
        openssl = shutil.which('openssl')
        if not openssl:
            raise RuntimeError('OpenSSL is required for one-time local certificate creation.')
        # Temporary private material is confined to a mode-0700 directory and
        # destroyed after import. The durable key lives only in the Keychain.
        with tempfile.TemporaryDirectory(prefix='glasssnap-signing-') as directory:
            temporary = Path(directory)
            os.chmod(temporary, 0o700)
            config = temporary / 'certificate.cnf'
            config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = GlassSnap Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
            key, certificate, archive = (temporary / name for name in ('identity.key', 'certificate.pem', 'identity.p12'))
            run([openssl, 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-x509', '-sha256', '-days', '3650',
                 '-config', config, '-keyout', key, '-out', certificate], capture=True)
            os.chmod(key, 0o600)
            # SHA-1 is the certificate selector used by codesign, not the signature digest.
            der = subprocess.check_output([openssl, 'x509', '-in', str(certificate), '-outform', 'DER'])
            fingerprint = hashlib.sha1(der).hexdigest().upper()
            environment = dict(os.environ, GLASSSNAP_IMPORT_PASSWORD=secrets.token_urlsafe(32))
            legacy = ['-legacy'] if run([openssl, 'version'], capture=True).startswith('OpenSSL 3.') else []
            run([openssl, 'pkcs12', '-export', *legacy, '-inkey', key, '-in', certificate, '-name', label,
                 '-out', archive, '-passout', 'env:GLASSSNAP_IMPORT_PASSWORD'], capture=True, env=environment)
            os.chmod(archive, 0o600)
            run(['/usr/bin/security', 'import', archive, '-k', keychain, '-P', environment['GLASSSNAP_IMPORT_PASSWORD'],
                 '-T', '/usr/bin/codesign'], capture=True)
            # Do not add a trusted root, change global trust, or grant all apps
            # access to this key. Signing verifies the exact pinned certificate.
    data = {'identity_sha1': fingerprint, 'keychain': keychain, 'bundle_identifier': bundle_id}
    descriptor = os.open(CONFIG, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')
    print('Saved local signing configuration. The private key stays in your Keychain.')
    print('Next: ./Scripts/update.sh --migrate-signing (one-time transition from ad-hoc signing).')


def running(app):
    executable = str(app.resolve() / 'Contents/MacOS/GlassSnap')
    lines = run(['/bin/ps', '-axo', 'pid=,comm='], capture=True).splitlines()
    return [int(parts[0]) for line in lines if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable]


def stop(app):
    pids = running(app)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 8
    while running(app):
        if time.monotonic() > deadline:
            raise RuntimeError('GlassSnap did not exit normally. Quit it manually, then rerun the update. No force-quit was used.')
        time.sleep(0.15)


def launch(app):
    run(['/usr/bin/open', app])
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if running(app):
            return
        time.sleep(0.15)
    raise RuntimeError('The installed app did not start. Check for another GlassSnap copy.')


def compatibility(data, migrate):
    if not TARGET.exists():
        return
    if info(TARGET)['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Installed bundle ID differs. Refusing an identity-changing update.')
    run(['/usr/bin/codesign', '--verify', '--strict', TARGET], capture=True)
    try:
        verify(TARGET, data)
    except RuntimeError:
        details = subprocess.run(['/usr/bin/codesign', '-dv', TARGET], capture_output=True, text=True).stderr
        if not migrate or 'Signature=adhoc' not in details:
            raise RuntimeError('Installed signature differs. Only a one-time ad-hoc transition is allowed with --migrate-signing. '
                               'Never regenerate the certificate to bypass this check.') from None
        print('One-time signing migration: macOS may require Accessibility and Screen Recording permission once more.')


def update(migrate=False, prepare=False):
    data = configuration()
    # Reject a changed identity before spending time building or touching the app.
    compatibility(data, migrate)
    run([ROOT / 'Scripts/test.sh'])
    run([ROOT / 'Scripts/build.sh'])
    verify(BUILD, data)
    if prepare:
        print('Prepared and verified. The installed app has not been changed.')
        return
    if not os.access(TARGET.parent, os.W_OK):
        raise RuntimeError('Applications is not writable. Allow the update tool access; do not run setup/build as root.')
    # Keep an independently verified rollback copy outside the signed bundle.
    backup = None
    if TARGET.exists():
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3)
        backup = ROOT / 'build/update-backups' / stamp / 'GlassSnap.app'
        backup.parent.mkdir(parents=True)
        run(['/usr/bin/ditto', TARGET, backup])
        run(['/usr/bin/codesign', '--verify', '--strict', backup], capture=True)
    with tempfile.TemporaryDirectory(prefix='.GlassSnap-update-', dir=TARGET.parent) as directory:
        stage = Path(directory)
        candidate, previous = stage / 'GlassSnap.app', stage / 'previous.app'
        run(['/usr/bin/ditto', BUILD, candidate])
        verify(candidate, data)
        # Only stop our two exact paths. Never kill unrelated apps by name.
        stop(BUILD)
        stop(TARGET)
        old_moved = False
        new_installed = False
        try:
            if TARGET.exists():
                os.replace(TARGET, previous)
                old_moved = True
            os.replace(candidate, TARGET)
            new_installed = True
            verify(TARGET, data)
            launch(TARGET)
        except Exception:
            if new_installed:
                stop(TARGET)
                os.replace(TARGET, stage / 'failed.app')
            if old_moved:
                os.replace(previous, TARGET)
                launch(TARGET)
            raise
    print('Updated and launched /Applications/GlassSnap.app with the saved signing identity.')
    if backup:
        print('Previous version retained under build/update-backups/.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    setup_parser = sub.add_parser('setup')
    setup_parser.add_argument('--identity', help='Reuse an existing certificate by exact SHA-1 fingerprint')
    sub.add_parser('check')
    sign_parser = sub.add_parser('sign')
    sign_parser.add_argument('app', type=Path)
    update_parser = sub.add_parser('update')
    update_parser.add_argument('--migrate-signing', action='store_true')
    update_parser.add_argument('--prepare', action='store_true', help='Build and verify without installing or restarting')
    args = parser.parse_args()
    try:
        if args.command == 'setup': setup(args.identity)
        elif args.command == 'check': configuration()
        elif args.command == 'sign': sign(args.app.resolve())
        else: update(args.migrate_signing, args.prepare)
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f'GlassSnap: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
