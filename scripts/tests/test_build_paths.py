"""Exercise Make path overrides without compiling or touching installed apps."""
import json
import os
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
