import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


class GenericBuildPathTests(unittest.TestCase):
    def fixture(self, root):
        repo = root / 'checkout with spaces'
        repo.mkdir()
        shutil.copy2(REPO / 'Makefile', repo / 'Makefile')
        for name in ['scripts/validate-local-debug-config.sh',
                     'scripts/plugins/generate-plugin-project-config.rb',
                     'scripts/plugins/sync-debug-plugins.sh', 'tools/xcodegen']:
            executable(repo / name, '#!/bin/sh\nexit 0\n')
        executable(repo / 'scripts/icons/generate-local-icon-gallery.py', 'pass\n')
        executable(repo / 'scripts/xcodebuild-filtered.sh', '''#!/usr/bin/python3
import json,sys
with open('build-args.jsonl','a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
''')
        executable(repo / 'scripts/install-debug-app.sh', '''#!/usr/bin/python3
import json,sys
from pathlib import Path
Path('install-args.json').write_text(json.dumps(sys.argv[1:]))
''')
        env = dict(os.environ, PATH=str(repo / 'tools') + ':' + os.environ['PATH'])
        for key in ('DERIVED_DATA', 'TEST_DERIVED_DATA', 'APP_PRODUCT_NAME', 'XCODEBUILD', 'PYTHON3'):
            env.pop(key, None)
        return repo, env

    def test_default_make_build_keeps_repository_local_output(self):
        with tempfile.TemporaryDirectory() as temp:
            repo, env = self.fixture(Path(temp))
            subprocess.run(['make', 'build'], cwd=repo, env=env, capture_output=True, text=True, check=True)
            args = json.loads((repo / 'build-args.jsonl').read_text().splitlines()[0])
            self.assertEqual(args[args.index('-derivedDataPath') + 1], 'build/DerivedData')

    def test_environment_build_path_override_keeps_tests_separate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo, env = self.fixture(root)
            debug = root / 'environment build storage/Debug'
            env['DERIVED_DATA'] = str(debug)
            subprocess.run(['make', 'build', 'test'], cwd=repo, env=env,
                           capture_output=True, text=True, check=True)
            calls = [json.loads(line) for line in (repo / 'build-args.jsonl').read_text().splitlines()]
            self.assertEqual([a[a.index('-derivedDataPath') + 1] for a in calls],
                             [str(debug), str(debug) + 'Tests'])

    def test_absolute_paths_with_spaces_reach_build_test_and_installer(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo, env = self.fixture(root)
            debug = root / 'custom build storage/Debug'
            tests = root / 'custom build storage/Tests'
            subprocess.run(['make', 'build', 'build-cli', 'test', 'install-debug-app',
                            'DERIVED_DATA=' + str(debug), 'TEST_DERIVED_DATA=' + str(tests)],
                           cwd=repo, env=env, capture_output=True, text=True, check=True)
            calls = [json.loads(line) for line in (repo / 'build-args.jsonl').read_text().splitlines()]
            self.assertEqual([a[a.index('-derivedDataPath') + 1] for a in calls], [str(debug), str(debug), str(tests)])
            installed = json.loads((repo / 'install-args.json').read_text())
            self.assertEqual(installed[0], str(debug / 'Build/Products/Debug/MacTools Dev.app'))


if __name__ == '__main__':
    unittest.main()
