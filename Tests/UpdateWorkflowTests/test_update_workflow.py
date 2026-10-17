"""Exercise update failure paths without touching the real app or Keychain."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
script = Path(__file__).resolve().parents[2] / 'Scripts/app-maintenance.py'
spec = importlib.util.spec_from_file_location('maintenance', script)
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class UpdateWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.target = self.root / 'Applications/GlassSnap.app'
        self.build = self.root / 'build/GlassSnap.app'
        for app, text in [(self.target, 'installed'), (self.build, 'updated')]:
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.GlassSnap'}))
            (app / 'version').write_text(text)
        self.config = {'identity_sha1': 'A' * 40, 'bundle_identifier': 'local.GlassSnap', 'keychain': '/unused'}
        self.patches = [patch.object(maintenance, 'ROOT', self.root),
                        patch.object(maintenance, 'TARGET', self.target),
                        patch.object(maintenance, 'BUILD', self.build)]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.directory.cleanup()

    def fake_run(self, args, **kwargs):
        if str(args[0]) == '/usr/bin/ditto':
            shutil.copytree(args[1], args[2])
        return ''

    def test_missing_config_never_falls_back_to_adhoc(self):
        with patch.object(maintenance, 'CONFIG', self.root / 'missing.json'):
            with self.assertRaisesRegex(RuntimeError, 'not configured'):
                maintenance.configuration()

    def test_changed_bundle_id_refuses_update(self):
        data = dict(self.config, bundle_identifier='local.OtherApp')
        with self.assertRaisesRegex(RuntimeError, 'bundle ID differs'):
            maintenance.compatibility(data, migrate=True)

    def test_different_certificate_cannot_use_migration_escape_hatch(self):
        with patch.object(maintenance, 'run', return_value=''), \
             patch.object(maintenance, 'verify', side_effect=RuntimeError('mismatch')), \
             patch.object(maintenance.subprocess, 'run') as process:
            process.return_value.stderr = 'Signature size=4000\nAuthority=Different Certificate'
            with self.assertRaisesRegex(RuntimeError, 'Only a one-time ad-hoc transition'):
                maintenance.compatibility(self.config, migrate=True)

    def test_build_failure_does_not_stop_installed_app(self):
        with patch.object(maintenance, 'configuration', return_value=self.config), \
             patch.object(maintenance, 'compatibility'), \
             patch.object(maintenance, 'run', side_effect=RuntimeError('test failed')), \
             patch.object(maintenance, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'test failed'):
                maintenance.update()
            stop.assert_not_called()
            self.assertEqual((self.target / 'version').read_text(), 'installed')

    def test_bad_staged_signature_leaves_installed_app_running(self):
        def verify(app, data):
            if '.GlassSnap-update-' in str(app): raise RuntimeError('bad staged signature')
        with patch.object(maintenance, 'configuration', return_value=self.config), \
             patch.object(maintenance, 'compatibility'), \
             patch.object(maintenance, 'run', side_effect=self.fake_run), \
             patch.object(maintenance, 'verify', side_effect=verify), \
             patch.object(maintenance, 'stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'bad staged signature'):
                maintenance.update()
            stop.assert_not_called()
            self.assertEqual((self.target / 'version').read_text(), 'installed')

    def test_failed_launch_restores_and_relaunches_previous_app(self):
        observed = []
        def launch(app):
            version = (app / 'version').read_text()
            observed.append(version)
            if version == 'updated': raise RuntimeError('launch failed')
        with patch.object(maintenance, 'configuration', return_value=self.config), \
             patch.object(maintenance, 'compatibility'), \
             patch.object(maintenance, 'run', side_effect=self.fake_run), \
             patch.object(maintenance, 'verify'), \
             patch.object(maintenance, 'stop'), \
             patch.object(maintenance, 'launch', side_effect=launch):
            with self.assertRaisesRegex(RuntimeError, 'launch failed'):
                maintenance.update()
        self.assertEqual(observed, ['updated', 'installed'])
        self.assertEqual((self.target / 'version').read_text(), 'installed')
        backups = list((self.root / 'build/update-backups').glob('*/GlassSnap.app/version'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'installed')

    def write_plists(self, public='io.example.GlassSnap', local='local.GlassSnap'):
        resources = self.root / 'Resources'
        resources.mkdir(exist_ok=True)
        base = {'CFBundleShortVersionString': '1.0.0'}
        (resources / 'Info.plist').write_bytes(plistlib.dumps(dict(base, CFBundleIdentifier=public)))
        (resources / 'Info.local.plist').write_bytes(plistlib.dumps(dict(base, CFBundleIdentifier=local)))
        keychain = self.root / 'login.keychain-db'
        keychain.write_text('')
        return keychain

    def fake_security(self, keychain, identities):
        listing = '\n'.join(f'  {n}) {sha} "{name}"' for n, (sha, name) in enumerate(identities, 1))
        def run(args, **kwargs):
            if args[1:3] == ['default-keychain', '-d']: return f'"{keychain}"'
            if args[1] == 'find-identity': return listing + f'\n     {len(identities)} valid identities found'
            return ''
        return run

    def release_config(self, keychain, **changes):
        return dict({'identity_sha1': 'B' * 40, 'keychain': str(keychain), 'bundle_identifier': 'io.example.GlassSnap',
                     'team_id': 'TEAM123456', 'notary_profile': 'glasssnap-notary'}, **changes)

    def test_release_setup_switches_self_signed_identity_to_developer_id(self):
        keychain = self.write_plists()
        release = self.root / 'release.json'
        release.write_text(maintenance.json.dumps({'identity_sha1': 'A' * 40, 'keychain': str(keychain),
                                                   'bundle_identifier': 'io.example.GlassSnap'}))
        identities = [('A' * 40, 'GlassSnap Local Development'), ('B' * 40, 'Developer ID Application: Example (TEAM123456)')]
        with patch.object(maintenance, 'RELEASE_CONFIG', release), \
             patch.object(maintenance, 'run', side_effect=self.fake_security(keychain, identities)) as run:
            maintenance.setup_release()
            saved = maintenance.json.loads(release.read_text())
            self.assertEqual(saved, self.release_config(keychain))
            self.assertEqual(maintenance.configuration(release=True), saved)
            self.assertIn('notarytool', [str(call.args[0][1]) for call in run.call_args_list])

    def test_release_setup_refuses_ambiguous_developer_id(self):
        keychain = self.write_plists()
        release = self.root / 'release.json'
        identities = [('B' * 40, 'Developer ID Application: Example (TEAM123456)'),
                      ('C' * 40, 'Developer ID Application: Example (TEAM123456)')]
        with patch.object(maintenance, 'RELEASE_CONFIG', release), \
             patch.object(maintenance, 'run', side_effect=self.fake_security(keychain, identities)):
            with self.assertRaisesRegex(RuntimeError, 'Several Developer ID'):
                maintenance.setup_release()
        self.assertFalse(release.exists())

    def test_self_signed_release_identity_is_refused(self):
        keychain = self.write_plists()
        release = self.root / 'release.json'
        release.write_text(maintenance.json.dumps({'identity_sha1': 'A' * 40, 'keychain': str(keychain),
                                                   'bundle_identifier': 'io.example.GlassSnap'}))
        with patch.object(maintenance, 'RELEASE_CONFIG', release):
            with self.assertRaisesRegex(RuntimeError, 'switch to Developer ID'):
                maintenance.configuration(release=True)

    def test_developer_id_signing_uses_hardened_runtime_and_team_requirement(self):
        keychain = self.write_plists()
        data = self.release_config(keychain)
        app = self.root / 'GlassSnap.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.example.GlassSnap'}))
        with patch.object(maintenance, 'configuration', return_value=data), \
             patch.object(maintenance, 'run', return_value='') as run:
            maintenance.sign(app, release=True)
        signing, verifying = [[str(a) for a in call.args[0]] for call in run.call_args_list]
        self.assertIn('runtime', signing)
        self.assertIn('--timestamp', signing)
        self.assertNotIn('--requirements', signing)
        self.assertIn('certificate leaf[subject.OU] = "TEAM123456"', verifying[4])

    def test_rejected_notarization_publishes_nothing(self):
        keychain = self.write_plists()
        data = self.release_config(keychain)
        build = self.root / 'build/release/GlassSnap.app'
        (build / 'Contents').mkdir(parents=True)
        (build / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.0.0'}))
        def notarytool(args, **kwargs):
            result = maintenance.subprocess.CompletedProcess(args, 0, '', '')
            if args[2] == 'submit': result.stdout = '{"id": "1", "status": "Invalid"}'
            if args[2] == 'log': result.stdout = 'The binary is not signed with a valid Developer ID certificate.'
            return result
        with patch.object(maintenance, 'RELEASE_BUILD', build), \
             patch.object(maintenance, 'ARCHIVE', self.root / 'dist/GlassSnap.zip'), \
             patch.object(maintenance, 'configuration', return_value=data), \
             patch.object(maintenance, 'verify'), \
             patch.object(maintenance, 'run', return_value='') as run, \
             patch.object(maintenance.subprocess, 'run', side_effect=notarytool):
            with self.assertRaisesRegex(RuntimeError, 'status Invalid(.|\n)*valid Developer ID'):
                maintenance.release()
        commands = [str(call.args[0][0]) for call in run.call_args_list]
        self.assertNotIn('gh', commands)
        self.assertNotIn('/usr/bin/xcrun', commands)

    def test_release_refuses_public_bundle_id_change(self):
        keychain = self.write_plists(public='io.example.Renamed')
        release = self.root / 'release.json'
        release.write_text(maintenance.json.dumps({'identity_sha1': 'A' * 40, 'keychain': str(keychain),
                                                   'bundle_identifier': 'io.example.GlassSnap'}))
        with patch.object(maintenance, 'RELEASE_CONFIG', release):
            with self.assertRaisesRegex(RuntimeError, 'Bundle identity changed'):
                maintenance.configuration(release=True)

    def test_publish_with_uncommitted_changes_builds_nothing(self):
        self.write_plists()
        with patch.object(maintenance, 'configuration', return_value=self.config), \
             patch.object(maintenance.shutil, 'which', return_value='/usr/bin/gh'), \
             patch.object(maintenance, 'run', return_value=' M Sources/GlassSnap/App.swift') as run:
            with self.assertRaisesRegex(RuntimeError, 'Commit or stash'):
                maintenance.release(publish=True)
            self.assertEqual([str(call.args[0][0]) for call in run.call_args_list], ['git'])


if __name__ == '__main__':
    unittest.main()
