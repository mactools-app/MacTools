"""Exercise Make path overrides without compiling or touching installed apps."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

REPO = Path(__file__).resolve().parents[2]


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content).lstrip(), encoding='utf-8')
    path.chmod(0o755)


class BuildPathTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / 'checkout with spaces'
        self.repo.mkdir()
        shutil.copy2(REPO / 'Makefile', self.repo / 'Makefile')
        self.log = self.root / 'tool-calls.jsonl'
        tools = self.repo / 'tools'
        tools.mkdir()
        (tools / 'python3').symlink_to(sys.executable)

        for name in ('scripts/validate-local-debug-config.sh',
                     'scripts/plugins/generate-plugin-project-config.rb',
                     'scripts/plugins/sync-debug-plugins.sh', 'tools/xcodegen'):
            executable(self.repo / name, '#!/bin/sh\nexit 0\n')
        for name in ('scripts/changelog.py', 'scripts/plugins/generate_website_plugin_data.py',
                     'scripts/audit-localization.py', 'scripts/plugins/generate-preferences-backup-inventory.py',
                     'scripts/icons/generate-local-icon-gallery.py'):
            executable(self.repo / name, 'pass\n')
        (self.repo / 'scripts/tests').mkdir()
        (self.repo / 'scripts/tests/test_fixture.py').write_text(
            'import unittest\nclass FixtureTests(unittest.TestCase):\n    def test_fixture(self):\n        pass\n',
            encoding='utf-8')

        for name, kind in (
            ('scripts/xcodebuild-filtered.sh', 'build'),
            ('scripts/install-debug-app.sh', 'install'),
            ('scripts/plugins/verify-plugin-kit-v7-binary-compatibility.sh', 'compatibility'),
            ('tools/lsregister', 'registration'),
        ):
            executable(self.repo / name, f'''\
                #!/usr/bin/env python3
                import json
                import os
                from pathlib import Path
                import sys

                record = {{'tool': {kind!r}, 'args': sys.argv[1:], 'cwd': str(Path.cwd())}}
                with open(os.environ['BUILD_PATH_TEST_LOG'], 'a', encoding='utf-8') as stream:
                    stream.write(json.dumps(record) + '\\n')
                ''')
        # Keep host Make flags, compiler overrides, and signing settings out of the fixture.
        self.env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
        self.env.update(PATH=str(tools) + os.pathsep + os.defpath + os.pathsep + self.env.get('PATH', ''),
                        HOME=str(self.root), TMPDIR=str(self.root), PYTHON3='python3',
                        LSREGISTER=str(tools / 'lsregister'),
                        BUILD_PATH_TEST_LOG=str(self.log))

    def run_make(self, environment=None, **overrides):
        if self.log.exists():
            self.log.unlink()
        command = ['make', 'build', 'build-cli', 'install-debug-app', 'ci']
        command.extend(f'{key}={value}' for key, value in overrides.items())
        result = subprocess.run(command, cwd=self.repo, env=environment or self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_paths(self, result, debug, tests):
        records = [json.loads(line) for line in self.log.read_text(encoding='utf-8').splitlines()]
        operations = set()
        for record in records:
            args = record['args']
            if record['tool'] != 'build' or '-derivedDataPath' not in args:
                continue
            operation = 'test' if 'test' in args else args[args.index('-scheme') + 1]
            operations.add(operation)
            expected = tests if operation == 'test' else debug
            self.assertEqual(args[args.index('-derivedDataPath') + 1], str(expected))
        self.assertEqual(operations, {'MacTools', 'MacToolsCLI', 'test'})

        app = (self.repo / debug / 'Build/Products/Debug/MacTools Dev.app').resolve()
        cli = (self.repo / debug / 'Build/Products/Debug/mactools').resolve()
        products = (self.repo / tests / 'Build/Products/Debug').resolve()
        for record in records:
            args = record['args']
            if record['tool'] == 'install':
                self.assertEqual((Path(record['cwd']) / args[0]).resolve(), app)
            elif record['tool'] == 'registration':
                self.assertEqual(args, ['-u', str(app)])
            elif record['tool'] == 'compatibility':
                self.assertEqual(args, [str(products)])
        self.assertTrue({'install', 'registration', 'compatibility'}.issubset(
            {record['tool'] for record in records}))
        self.assertIn(str(cli), result.stdout)

    def test_default_paths_remain_local_and_separate(self):
        result = self.run_make()
        self.assert_paths(result, Path('build/DerivedData'), Path('build/DerivedDataTests'))

    def test_environment_override_and_command_line_precedence(self):
        inherited = self.root / 'environment build storage/Debug'
        environment = dict(self.env, DERIVED_DATA=str(inherited))
        self.assert_paths(self.run_make(environment), inherited, Path(str(inherited) + 'Tests'))
        explicit = self.root / 'explicit build storage/Debug'
        self.assert_paths(self.run_make(environment, DERIVED_DATA=explicit),
                          explicit, Path(str(explicit) + 'Tests'))

    def test_relative_and_absolute_paths_with_spaces_reach_every_consumer(self):
        for debug, tests in (
            (Path('custom build /Debug'), Path('custom tests /Tests')),
            (self.root / 'custom build storage/Debug', self.root / 'custom build storage/Tests'),
        ):
            with self.subTest(debug=debug, tests=tests):
                result = self.run_make(DERIVED_DATA=debug, TEST_DERIVED_DATA=tests)
                self.assert_paths(result, debug, tests)

    def test_e2e_rebuild_installs_the_configured_app_and_preserves_source_checks(self):
        harness = self.repo / 'scripts/e2e/mactools-e2e.sh'
        harness.parent.mkdir()
        shutil.copy2(REPO / 'scripts/e2e/mactools-e2e.sh', harness)
        # Keep signing, process detection, registration, and launch inside the fixture.
        harness_source = harness.read_text(encoding='utf-8').replace('/usr/bin/open ', 'open ')
        harness_source = re.sub(r'^LSREGISTER=.*$', 'LSREGISTER=/usr/bin/true',
                                harness_source, flags=re.MULTILINE)
        harness.write_text(harness_source, encoding='utf-8')
        for helper in ('MacToolsE2ECaptureRect.swift', 'MacToolsE2ERecorder.swift'):
            (harness.parent / helper).touch()
        executable(self.repo / 'tools/codesign', '''\
            #!/bin/sh
            if [ "$1" = -dv ]; then
                printf '%s\\n' 'CDHash=fixture' 'TeamIdentifier=FIXTURE' 'Authority=Apple Development: Fixture'
            fi
            ''')
        executable(self.repo / 'tools/open', '''\
            #!/bin/sh
            printf '%s\\n' "$@" > "$FIXTURE_LAUNCH_LOG"
            ''')
        executable(self.repo / 'tools/pgrep', '''\
            #!/usr/bin/env python3
            import os
            import re
            import sys

            if re.fullmatch(sys.argv[-1], os.environ.get('FIXTURE_RUNNING_EXECUTABLE', '')):
                print(4242)
            else:
                sys.exit(1)
            ''')
        executable(self.repo / 'tools/xcrun', '#!/bin/sh\nexit 1\n')
        executable(self.repo / 'scripts/plugins/sync-debug-plugins.sh', '''\
            #!/bin/sh
            touch "$MACTOOLS_E2E_PLUGIN_DIR/fixture.mactoolsplugin/synced"
            printf '%s\\n' '{"synced": true}' > "$MACTOOLS_E2E_PLUGIN_CATALOG_PATH"
            ''')
        with (self.repo / 'scripts/xcodebuild-filtered.sh').open('a', encoding='utf-8') as stub:
            stub.write("\noutput = Path(sys.argv[sys.argv.index('-derivedDataPath') + 1])\n"
                       "with (output / 'generated-build-data').open('a') as generated:\n"
                       "    generated.write('build\\n')\n")
        (self.repo / '.gitignore').write_text('/build/\n', encoding='utf-8')
        subprocess.run(['git', 'init', '-q'], cwd=self.repo, env=self.env, check=True)
        subprocess.run(['git', 'add', '.'], cwd=self.repo, env=self.env, check=True)
        subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                        '-c', 'commit.gpgSign=false', 'commit', '-q', '-m', 'Fixture'],
                       cwd=self.repo, env=self.env, check=True)

        app = self.root / 'Installed MacTools.app'
        executable(app / 'Contents/MacOS/MacTools', '#!/bin/sh\nexit 0\n')
        bundle_id = 'com.example.mactools-test'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'MacTools',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
        }))
        artifacts = self.root / 'artifacts'
        session = artifacts / 'session'
        session.mkdir(parents=True)
        plugins = self.root / 'plugins'
        (plugins / 'fixture.mactoolsplugin').mkdir(parents=True)
        catalog = self.root / 'catalog.json'
        catalog.write_bytes(b'{}')
        (session / 'session.plist').write_bytes(plistlib.dumps({
            'appPath': str(app), 'bundleIdentifier': bundle_id, 'extensionBundleIdentifier': '',
            'appVersion': '1.0', 'appBuild': '1', 'sourceCommit': 'fixture', 'sourceDirty': False,
            'sourceTreeSHA256': 'fixture', 'sourceBuildBound': False,
            'appExecutableSHA256': hashlib.sha256((app / 'Contents/MacOS/MacTools').read_bytes()).hexdigest(),
            'appCodeDirectoryHash': 'fixture',
            'pluginPackageTreeSHA256': hashlib.sha256(b'fixture.mactoolsplugin\0D\0\0').hexdigest(),
            'pluginCatalogSHA256': hashlib.sha256(catalog.read_bytes()).hexdigest(),
            'hadPreferences': False, 'hadExtensionPreferences': False,
        }))

        custom = Path('custom products [qa]')
        products = Path('Build/Products/Debug')
        current = self.repo / custom / products / 'MacTools Dev.app'
        stale = self.repo / 'build/DerivedData' / products / app.name
        shutil.copytree(app, current)
        (current / 'marker').write_text('current', encoding='utf-8')
        (stale / 'Contents').mkdir(parents=True)
        (stale / 'Contents/Info.plist').write_bytes(plistlib.dumps({}))
        launch_log = self.root / 'launch.log'
        env = dict(self.env, DERIVED_DATA='build/DerivedData',
                   MACTOOLS_E2E_APP_PATH=str(app), MACTOOLS_E2E_ARTIFACT_ROOT=str(artifacts),
                   MACTOOLS_E2E_PLUGIN_DIR=str(plugins), MACTOOLS_E2E_PLUGIN_CATALOG_PATH=str(catalog),
                   MACTOOLS_E2E_FFMPEG='/usr/bin/true', MACTOOLS_E2E_FFPROBE='/usr/bin/true',
                   FIXTURE_LAUNCH_LOG=str(launch_log))
        rebuild = ['make', 'e2e-rebuild', f'E2E_SESSION={session}', f'DERIVED_DATA={custom}']
        running = dict(env, FIXTURE_RUNNING_EXECUTABLE=str(current / 'Contents/MacOS/MacTools'))
        result = subprocess.run(rebuild, cwd=self.repo, env=running, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('a MacTools app is still running from Derived Data', result.stderr)
        self.assertFalse((app / 'marker').exists())
        self.assertFalse(list(session.glob('app-before-rebuild-*.app')))
        self.assertFalse(launch_log.exists())
        self.assertFalse((plugins / 'fixture.mactoolsplugin/synced').exists())
        self.assertEqual(catalog.read_bytes(), b'{}')

        result = subprocess.run(rebuild, cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((app / 'marker').read_text(encoding='utf-8'), 'current')
        self.assertEqual(launch_log.read_text(encoding='utf-8').splitlines()[:3], ['-n', '-a', str(app)])
        self.assertTrue((plugins / 'fixture.mactoolsplugin/synced').is_file())
        self.assertEqual(json.loads(catalog.read_bytes()), {'synced': True})
        self.assertEqual((self.repo / custom / 'generated-build-data').read_text(encoding='utf-8'),
                         'build\nbuild\n')
        records = [json.loads(line) for line in self.log.read_text(encoding='utf-8').splitlines()]
        build_args = [record['args'] for record in records if record['tool'] == 'build']
        self.assertEqual([args[args.index('-derivedDataPath') + 1] for args in build_args],
                         [str(custom), str(custom)])

        # Resume must detect a running copy in the current configuration as well as the recorded one.
        current_override = self.root / 'external build products'
        override_app = current_override / products / current.name
        shutil.copytree(app, override_app)
        for variant in ('Primary', 'Secondary', 'Backdrop'):
            helper = session / f'privacy-helpers/MacTools E2E {variant.upper()} Helper.app'
            executable(helper / 'Contents/MacOS' / f'MacToolsE2E{variant}Helper', '#!/bin/sh\nexit 0\n')
        resume = [str(harness), 'resume', str(session)]
        running = dict(env, DERIVED_DATA=str(current_override),
                       FIXTURE_RUNNING_EXECUTABLE=str(override_app / 'Contents/MacOS/MacTools'))
        launch_log.unlink()
        result = subprocess.run(resume, env=running, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('a MacTools app is still running from Derived Data', result.stderr)
        self.assertFalse(launch_log.exists())

        # An older session's single exclusion must survive switching to another build directory.
        metadata_path = session / 'session.plist'
        metadata = plistlib.loads(metadata_path.read_bytes())
        custom_tests = Path(f'{custom}Tests')
        self.assertCountEqual(metadata.pop('sourceOutputDirectories'), [str(custom), str(custom_tests)])
        metadata['sourceOutputDirectory'] = str(custom)
        metadata_path.write_bytes(plistlib.dumps(metadata))
        start_recording = [str(harness), 'start-recording', str(session)]
        other = Path('second build products')
        other_app = self.repo / other / products / current.name
        shutil.copytree(app, other_app)
        (other_app / 'marker').write_text('second', encoding='utf-8')
        test_override = Path('custom test products')
        for directory in (custom, other, test_override):
            checkout = self.repo / directory / 'SourcePackages/checkouts/fixture'
            checkout.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(checkout)], env=self.env, check=True)
        result = subprocess.run(
            rebuild[:-1] + [f'DERIVED_DATA={other}', f'TEST_DERIVED_DATA={test_override}'],
            cwd=self.repo, env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('IsADirectoryError', result.stderr)
        self.assertEqual((app / 'marker').read_text(encoding='utf-8'), 'second')
        metadata = plistlib.loads(metadata_path.read_bytes())
        self.assertCountEqual(metadata['sourceOutputDirectories'], [str(custom), str(other), str(test_override)])
        for directory in (custom, other, test_override):
            (self.repo / directory / 'later-generated-file').touch()
        result = subprocess.run(start_recording, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with (self.repo / 'Makefile').open('a', encoding='utf-8') as makefile:
            makefile.write('\n# Source change after rebuild\n')
        result = subprocess.run(start_recording, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('session source revision does not match the current checkout', result.stderr)

    def test_preferences_backup_links_against_its_test_products(self):
        script = self.repo / 'scripts/testing/preferences-backup/run.sh'
        script.parent.mkdir(parents=True)
        shutil.copy2(REPO / 'scripts/testing/preferences-backup/run.sh', script)
        # Stub the capture programs and stop after recording the desktop helper's linker inputs.
        executable(self.repo / 'tools/xcrun', '''\
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import sys

            args = sys.argv[1:]
            if '-parse-as-library' in args:
                with open(os.environ['BUILD_PATH_TEST_LOG'], 'a', encoding='utf-8') as stream:
                    stream.write(json.dumps({'tool': 'link', 'args': args}) + '\\n')
                sys.exit(77)
            Path(args[args.index('-o') + 1]).symlink_to('/usr/bin/true')
            ''')
        tests = Path('build/custom tests')
        result = subprocess.run([str(script)], cwd=self.root,
                                env=dict(self.env, TEST_DERIVED_DATA=str(tests)),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        build, link = [json.loads(line)['args'] for line in
                       self.log.read_text(encoding='utf-8').splitlines()]
        self.assertEqual(build[build.index('-derivedDataPath') + 1], str(tests))
        products = str(self.repo / tests / 'Build/Products/Debug')
        for flag in ('-I', '-F', '-L'):
            self.assertEqual(link[link.index(flag) + 1], products)
        self.assertEqual(link[link.index('-rpath') + 1:link.index('-rpath') + 3],
                         ['-Xlinker', products])


if __name__ == '__main__':
    unittest.main()
