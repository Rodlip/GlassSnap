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

    def test_release_setup_reuses_local_certificate_with_public_bundle_id(self):
        keychain = self.write_plists()
        local, release = self.root / 'local.json', self.root / 'release.json'
        local.write_text(maintenance.json.dumps(dict(self.config, keychain=str(keychain))))
        with patch.object(maintenance, 'CONFIG', local), patch.object(maintenance, 'RELEASE_CONFIG', release), \
             patch.object(maintenance, 'run') as run:
            maintenance.setup_release()
            run.assert_not_called()
            saved = maintenance.json.loads(release.read_text())
            self.assertEqual(saved['identity_sha1'], 'A' * 40)
            self.assertEqual(saved['bundle_identifier'], 'io.example.GlassSnap')
            self.assertEqual(maintenance.configuration(release=True), saved)

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
