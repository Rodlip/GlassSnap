#!/usr/bin/env python3
"""Local certificate signing, notarized Developer ID releases, and verified, recoverable app updates. No TCC edits."""
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
# Public releases use the public bundle ID, Developer ID signing, and Apple
# notarization. macOS ties Accessibility and Screen Recording grants to the
# Team ID, so every release must come from the same Apple developer team.
RELEASE_CONFIG = ROOT / '.glasssnap-release.local.json'
NOTARY_PROFILE = 'glasssnap-notary'
TARGET = Path('/Applications/GlassSnap.app')
BUILD = ROOT / 'build/GlassSnap.app'
RELEASE_BUILD = ROOT / 'build/release/GlassSnap.app'
ARCHIVE = ROOT / 'dist/GlassSnap.zip'


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


def build_info(release=False):
    path = ROOT / 'Resources/Info.local.plist'
    if release or not path.exists():
        path = ROOT / 'Resources/Info.plist'
    with path.open('rb') as stream:
        return plistlib.load(stream)


def configuration(release=False):
    path = RELEASE_CONFIG if release else CONFIG
    if not path.exists():
        if release:
            raise RuntimeError('Release signing is not configured. Run ./Scripts/setup-signing.sh --release first.')
        raise RuntimeError('Stable signing is not configured. Run ./Scripts/setup-signing.sh first. '
                           'For a disposable unsigned-identity build only, use ./Scripts/build.sh --adhoc.')
    data = json.loads(path.read_text())
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', data.get('identity_sha1', '')):
        raise RuntimeError('Invalid signing fingerprint in local configuration.')
    if not re.fullmatch(r'[A-Za-z0-9.-]+', data.get('bundle_identifier', '')):
        raise RuntimeError('Invalid bundle identifier in local configuration.')
    if build_info(release)['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Bundle identity changed. Restore the local plist; do not reset permissions or replace the signing identity.')
    if not Path(data['keychain']).is_file():
        raise RuntimeError('The configured keychain is unavailable. Restore it; do not generate another identity.')
    if release:
        if 'team_id' not in data:
            raise RuntimeError('Release signing still uses the self-signed certificate. '
                               'Run ./Scripts/setup-signing.sh --release to switch to Developer ID.')
        if not re.fullmatch(r'[A-Z0-9]{10}', data['team_id']):
            raise RuntimeError('Invalid Team ID in release configuration.')
        if not re.fullmatch(r'[A-Za-z0-9._-]+', data.get('notary_profile', '')):
            raise RuntimeError('Invalid notarization profile in release configuration.')
    return data


def requirement(data):
    if 'team_id' in data:
        # Apple's Developer ID requirement: any certificate Apple issues to this
        # team satisfies it, so a renewed certificate keeps users' permissions.
        return (f'identifier "{data["bundle_identifier"]}" and anchor apple generic'
                ' and certificate 1[field.1.2.840.113635.100.6.2.6]'
                ' and certificate leaf[field.1.2.840.113635.100.6.1.13]'
                f' and certificate leaf[subject.OU] = "{data["team_id"]}"')
    # Pin both the app identifier and the actual certificate, never just a name.
    return f'identifier "{data["bundle_identifier"]}" and certificate leaf = H"{data["identity_sha1"]}"'


def verify(app, data):
    if info(app)['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Application bundle identifier does not match the saved signing identity.')
    run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement(data), app], capture=True)


def sign(app, release=False):
    data = configuration(release)
    if info(app)['CFBundleIdentifier'] != data['bundle_identifier']:
        raise RuntimeError('Refusing to sign a bundle with a different identifier.')
    if 'team_id' in data:
        # Notarization needs the hardened runtime and a secure timestamp. The
        # default designated requirement already names the bundle ID and team.
        run(['/usr/bin/codesign', '--force', '--sign', data['identity_sha1'], '--keychain', data['keychain'],
             '--options', 'runtime', '--timestamp', '--identifier', data['bundle_identifier'], app])
    else:
        run(['/usr/bin/codesign', '--force', '--sign', data['identity_sha1'], '--keychain', data['keychain'],
             '--timestamp=none', '--identifier', data['bundle_identifier'],
             '--requirements', '=designated => ' + requirement(data), app])
    verify(app, data)


def save_configuration(path, data):
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')


def developer_id(keychain, identity=None):
    """Find the Developer ID Application certificate that Xcode created; never create one here."""
    if identity and not re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
        raise RuntimeError('--identity must be the exact 40-character certificate fingerprint, not an ambiguous display name.')
    listing = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain], capture=True)
    found = dict(re.findall(r'\b([0-9A-F]{40}) "Developer ID Application: [^"]*\(([A-Z0-9]{10})\)"', listing))
    if identity:
        found = {fingerprint: team for fingerprint, team in found.items() if fingerprint == identity.upper()}
    if not found:
        raise RuntimeError('No valid Developer ID Application certificate is in your login Keychain. '
                           'Create one in Xcode → Settings → Accounts → Manage Certificates.')
    if len(found) > 1:
        raise RuntimeError('Several Developer ID certificates are available. Choose one with --identity <SHA-1 fingerprint>.')
    return next(iter(found.items()))


def setup_release(identity=None):
    if RELEASE_CONFIG.exists():
        if 'team_id' in json.loads(RELEASE_CONFIG.read_text()):
            configuration(release=True)
            print('Release signing is already configured. Keeping the existing identity.')
            return
        print('Replacing the self-signed release identity with Developer ID (a one-time switch).')
    keychain = run(['/usr/bin/security', 'default-keychain', '-d', 'user'], capture=True).strip('"')
    fingerprint, team = developer_id(keychain, identity)
    bundle_id = build_info(release=True)['CFBundleIdentifier']
    if not re.fullmatch(r'[A-Za-z0-9.-]+', bundle_id):
        raise RuntimeError('Unsupported bundle identifier.')
    # Fail now rather than after a full build if notarization can't sign in.
    try:
        run(['/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile', NOTARY_PROFILE], capture=True)
    except RuntimeError:
        raise RuntimeError(f'No working notarization profile named {NOTARY_PROFILE}. Run: xcrun notarytool '
                           f'store-credentials {NOTARY_PROFILE} --apple-id <Apple ID> --team-id {team}') from None
    RELEASE_CONFIG.unlink(missing_ok=True)
    save_configuration(RELEASE_CONFIG, {'identity_sha1': fingerprint, 'keychain': keychain, 'bundle_identifier': bundle_id,
                                        'team_id': team, 'notary_profile': NOTARY_PROFILE})
    print(f'Releases of {bundle_id} will be signed with Developer ID (team {team}) and notarized.')
    print('Users keep their permissions as long as every release comes from this team.')


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
    save_configuration(CONFIG, {'identity_sha1': fingerprint, 'keychain': keychain, 'bundle_identifier': bundle_id})
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


def publishable(tag):
    if not shutil.which('gh'):
        raise RuntimeError('Publishing needs the GitHub CLI (gh), signed in to this repository.')
    if run(['git', 'status', '--porcelain'], capture=True):
        raise RuntimeError('Commit or stash your changes first; a release must match a pushed commit.')
    head = run(['git', 'rev-parse', 'HEAD'], capture=True)
    run(['git', 'fetch', '--quiet', 'origin'])
    if subprocess.run(['git', 'merge-base', '--is-ancestor', head, '@{upstream}'], cwd=ROOT).returncode:
        raise RuntimeError('Push this commit first; the release is tagged at the current commit.')
    if subprocess.run(['gh', 'release', 'view', tag], cwd=ROOT, capture_output=True).returncode == 0:
        raise RuntimeError(f'{tag} is already published. Raise CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist.')
    return head


def release_notes(digest):
    return ('Download **GlassSnap.zip**, open it, and move GlassSnap to Applications. '
            'It’s signed with Developer ID and notarized by Apple, so it opens normally. Or install from Terminal:\n\n'
            '```\ncurl -fsSL https://raw.githubusercontent.com/Rodlip/GlassSnap/main/Scripts/install.sh | bash\n```\n\n'
            'Already installed? Choose **Check for Updates…** from the GlassSnap menu.\n\n'
            '**Coming from 0.3.0?** That version was signed differently, so Check for Updates can’t install this one. '
            'Run the Terminal command above, or quit GlassSnap and replace it with this download. Then turn its '
            'permissions on again: in **System Settings → Privacy & Security → Accessibility**, select GlassSnap, click '
            '**–**, then open GlassSnap and click **Enable access**. Do the same under **Screen & System Audio Recording** '
            'if you use previews. This happens once; later updates keep your permissions.\n\n'
            f'SHA-256: `{digest}`')


def package():
    ARCHIVE.parent.mkdir(exist_ok=True)
    ARCHIVE.unlink(missing_ok=True)
    # Leave out local extended attributes; the signature doesn't need them.
    run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', RELEASE_BUILD, ARCHIVE])


def notarize(data):
    """Have Apple notarize the archive, then staple the ticket so Gatekeeper accepts it offline."""
    print('Submitting to Apple for notarization. This usually takes a few minutes…')
    profile = ['--keychain-profile', data['notary_profile']]
    submitted = subprocess.run(['/usr/bin/xcrun', 'notarytool', 'submit', str(ARCHIVE), *profile, '--wait',
                                '--output-format', 'json'], cwd=ROOT, capture_output=True, text=True)
    try:
        result = json.loads(submitted.stdout)
    except ValueError:
        raise RuntimeError(f'notarytool failed ({submitted.returncode}). {submitted.stderr.strip()}') from None
    if result.get('status') != 'Accepted':
        log = ''
        if result.get('id'):
            log = subprocess.run(['/usr/bin/xcrun', 'notarytool', 'log', result['id'], *profile],
                                 cwd=ROOT, capture_output=True, text=True).stdout
        raise RuntimeError(f'Notarization finished with status {result.get("status", "unknown")}. Nothing was published.\n{log}')
    run(['/usr/bin/xcrun', 'stapler', 'staple', RELEASE_BUILD], capture=True)
    run(['/usr/bin/xcrun', 'stapler', 'validate', RELEASE_BUILD], capture=True)
    verify(RELEASE_BUILD, data)
    # Ask Gatekeeper directly, the same check a downloaded copy gets.
    assessment = subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '-vv', str(RELEASE_BUILD)],
                                capture_output=True, text=True)
    if assessment.returncode or 'Notarized Developer ID' not in assessment.stderr:
        raise RuntimeError(f'Gatekeeper rejected the notarized app. {assessment.stderr.strip()}')


def release(publish=False):
    data = configuration(release=True)
    version = build_info(release=True)['CFBundleShortVersionString']
    tag = 'v' + version
    commit = publishable(tag) if publish else None
    run([ROOT / 'Scripts/test.sh'])
    run([ROOT / 'Scripts/build.sh', '--release'])
    verify(RELEASE_BUILD, data)
    if info(RELEASE_BUILD)['CFBundleShortVersionString'] != version:
        raise RuntimeError('The built app reports a different version than Resources/Info.plist.')
    package()
    notarize(data)
    # Repackage so the download carries the stapled ticket.
    package()
    digest = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    print(f'Packaged notarized GlassSnap {version}: {ARCHIVE.relative_to(ROOT)} (SHA-256 {digest})')
    if not publish:
        print('Not published. Run ./Scripts/release.sh --publish to create the GitHub release.')
        return
    notes = release_notes(digest)
    run(['gh', 'release', 'create', tag, ARCHIVE, '--target', commit, '--title', f'GlassSnap {version}', '--notes', notes])
    print(f'Published {tag}.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    setup_parser = sub.add_parser('setup')
    setup_parser.add_argument('--identity', help='Reuse an existing certificate by exact SHA-1 fingerprint')
    setup_parser.add_argument('--release', action='store_true', help='Configure Developer ID signing and notarization for public GitHub releases')
    check_parser = sub.add_parser('check')
    check_parser.add_argument('--release', action='store_true')
    sign_parser = sub.add_parser('sign')
    sign_parser.add_argument('--release', action='store_true')
    sign_parser.add_argument('app', type=Path)
    release_parser = sub.add_parser('release')
    release_parser.add_argument('--publish', action='store_true', help='Create the GitHub release after packaging')
    update_parser = sub.add_parser('update')
    update_parser.add_argument('--migrate-signing', action='store_true')
    update_parser.add_argument('--prepare', action='store_true', help='Build and verify without installing or restarting')
    args = parser.parse_args()
    try:
        if args.command == 'setup': setup_release(args.identity) if args.release else setup(args.identity)
        elif args.command == 'check': configuration(args.release)
        elif args.command == 'sign': sign(args.app.resolve(), args.release)
        elif args.command == 'release': release(args.publish)
        else: update(args.migrate_signing, args.prepare)
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f'GlassSnap: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
