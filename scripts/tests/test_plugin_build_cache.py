"""Fallback plugin compiles reuse output without racing the packaging consumer."""
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from test_copy_plugin_manifest import runtime_envelope

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'scripts/plugins/build-local-plugins.sh'


class PluginBuildCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source/Example'
        self.source.mkdir(parents=True)
        (self.source / 'Example.xcodeproj').mkdir()
        (self.source / 'plugin.json').write_text(json.dumps(runtime_envelope(
            build={'project': 'Example.xcodeproj', 'scheme': 'Example'})))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('MACTOOLS_PLUGIN_')}
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        PYTHON3=sys.executable, DEVELOPER_DIR=str(self.root / 'Xcode/Developer'),
                        MACTOOLS_PLUGIN_CACHE_ROOT=str(self.root / 'compiler'), CALLS=str(self.root / 'calls'))
        self.tool('xcrun', "import os\nprint(os.environ.get('SDK_BUILD','fixture-sdk'))\n")
        self.builder = self.tool('xcodebuild', '''import json,os,pathlib,sys
if '-version' in sys.argv:
 print('fixture-xcode')
 sys.exit(0)
derived=pathlib.Path(sys.argv[sys.argv.index('-derivedDataPath')+1])
products=derived/'Build/Products'/os.environ.get('PRODUCT_DIRECTORY','')/sys.argv[sys.argv.index('-configuration')+1]
name=os.environ.get('PRODUCT_NAME','Example.bundle')
if '-showBuildSettings' in sys.argv:
 print(json.dumps([{'buildSettings':{'TARGET_BUILD_DIR':str(products),'FULL_PRODUCT_NAME':name}}]))
 sys.exit(0)
with open(os.environ['CALLS'],'a') as stream: stream.write(str(derived)+'\\n')
bundle=products/name
bundle.mkdir(parents=True,exist_ok=True)
(bundle/'payload').write_text(os.environ.get('BUNDLE_PAYLOAD','built plugin'))
print('Fixture build log',flush=True)
sys.exit(int(os.environ.get('BUILD_EXIT','0')))
''')
        self.tool('ditto', '''import os,pathlib,subprocess,sys,time
if os.environ.get('HOLD_COPY'):
 pathlib.Path(os.environ['HOLD_COPY']).touch()
 deadline=time.monotonic()+8
 while not pathlib.Path(os.environ['RELEASE_COPY']).exists() and time.monotonic()<deadline: time.sleep(.02)
sys.exit(subprocess.call(['/usr/bin/ditto',*sys.argv[1:]]))
''')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!' + sys.executable + '\n' + body)
        path.chmod(0o755)
        return path

    def command(self, label, *extra):
        return [str(SCRIPT), '--source-dir', str(self.source), '--output-dir', str(self.root / label),
                '--xcodebuild', str(self.builder), '--skip-catalog', *extra]

    def invoke(self, label, *extra, env=None):
        return subprocess.run(self.command(label, *extra), env=env or self.env,
                              text=True, capture_output=True, timeout=20)

    def reports(self):
        return sorted(self.root.glob('*/BuildReports/*/build.json'), key=lambda p: p.stat().st_mtime_ns)

    def latest(self):
        return json.loads(self.reports()[-1].read_text())

    def wait_for(self, condition):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(.02)
        self.fail('Timed out waiting for fixture workflow')

    def stop(self, child):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)

    def test_reuses_compiler_across_outputs_and_keeps_packaged_products_and_logs(self):
        self.assertEqual(self.invoke('first').returncode, 0)
        first = self.latest()
        retained = Path(first['workspace']) / 'retained-compiler-marker'
        retained.touch()
        self.assertEqual(self.invoke('second').returncode, 0)
        second = self.latest()
        self.assertEqual(first['workspace'], second['workspace'])
        self.assertNotEqual(first['report'], second['report'])
        self.assertTrue(retained.exists())
        self.assertEqual(len(set((self.root / 'calls').read_text().splitlines())), 1)
        for label, report in [('first', first), ('second', second)]:
            self.assertEqual((self.root / label / 'Packages/example.mactoolsplugin/Example.bundle/payload').read_text(), 'built plugin')
            self.assertIn('Fixture build log', Path(report['report'], 'build.log').read_text())
            self.assertFalse((self.root / label / 'DerivedData').exists())

    def test_symlinked_checkout_keeps_official_plugin_notices(self):
        checkout = self.root / 'checkout'
        for relative in ['scripts/plugins/build-local-plugins.sh', 'scripts/plugins/with-build-cache.py',
                         'scripts/plugins/copy-plugin-manifest.py', 'scripts/plugins/plugin_source_manifest.py',
                         'Configs/AppVersion.xcconfig']:
            target = checkout / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / relative, target)
        shutil.copytree(self.source, checkout / 'Plugins/Example')
        generator = checkout / 'scripts/licenses/generate-third-party-notices.py'
        generator.parent.mkdir(parents=True)
        generator.write_text('import pathlib,sys\npathlib.Path(sys.argv[sys.argv.index("--output")+1]).write_text("Required notice")\n')
        alias = self.root / 'checkout-alias'
        alias.symlink_to(checkout, target_is_directory=True)
        result = subprocess.run(
            ['/bin/bash', '-c', 'cd "$1" && exec ./scripts/plugins/build-local-plugins.sh "${@:2}"',
             'fixture', str(alias), '--source-dir', 'Plugins', '--output-dir', str(self.root / 'aliased'),
             '--xcodebuild', str(self.builder), '--skip-catalog'],
            env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'aliased/Packages/example.mactoolsplugin/THIRD_PARTY_NOTICES.txt').read_text(),
                         'Required notice')

    def test_configuration_signing_sdk_probe_and_fresh_workspaces_are_separate(self):
        cases = [([], {}), (['--configuration', 'Release'], {}), (['--unsigned-build'], {}),
                 ([], {'SDK_BUILD': 'changed-sdk'}), ([], {'MACTOOLS_PLUGIN_CACHE_VARIANT': 'probe'}),
                 ([], {'MACTOOLS_PLUGIN_FRESH_BUILD': '1'}), ([], {'MACTOOLS_PLUGIN_FRESH_BUILD': '1'})]
        workspaces = []
        for number, (extra, changes) in enumerate(cases):
            result = self.invoke('run-' + str(number), *extra, env=dict(self.env, **changes))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            workspaces.append(self.latest()['workspace'])
        self.assertEqual(len(workspaces), len(set(workspaces)))
        self.assertTrue(all(Path(p).exists() for p in workspaces))

    def test_lock_covers_bundle_copy_before_next_compile(self):
        held, release = self.root / 'copy-started', self.root / 'copy-release'
        first = subprocess.Popen(self.command('first'), env=dict(self.env, HOLD_COPY=str(held), RELEASE_COPY=str(release)),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop, first)
        self.wait_for(held.exists)
        second = subprocess.Popen(self.command('second'), env=self.env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop, second)
        self.wait_for(lambda: len(self.reports()) == 2 and self.latest().get('lock_contended'))
        self.assertEqual((self.root / 'calls').read_text().count('\n'), 1)
        release.touch()
        self.assertEqual(first.wait(timeout=10), 0)
        self.assertEqual(second.wait(timeout=10), 0)

    def test_failure_retains_report_and_allows_following_run(self):
        failed = self.invoke('failed', env=dict(self.env, BUILD_EXIT='42'))
        self.assertNotEqual(failed.returncode, 0)
        record = self.latest()
        self.assertEqual(record['state'], 'failed')
        self.assertIn('Fixture build log', Path(record['report'], 'build.log').read_text())
        self.assertEqual(self.invoke('following').returncode, 0)
        self.assertEqual(self.latest()['workspace'], record['workspace'])

    def test_report_remains_readable_while_an_update_is_being_written(self):
        shim = self.root / 'shim'
        shim.mkdir()
        (shim / 'sitecustomize.py').write_text('''import json,os,pathlib,time
original=pathlib.Path.write_text
def write_text(path,data,*args,**kwargs):
 if path.name in {'build.json','build.json.tmp'} and json.loads(data).get('state')=='running':
  with path.open('w') as stream:
   pathlib.Path(os.environ['REPORT_WRITE_STARTED']).touch()
   deadline=time.monotonic()+8
   while not pathlib.Path(os.environ['RELEASE_REPORT_WRITE']).exists() and time.monotonic()<deadline: time.sleep(.02)
   return stream.write(data)
 return original(path,data,*args,**kwargs)
pathlib.Path.write_text=write_text
''')
        held, release = self.root / 'report-started', self.root / 'report-release'
        child = subprocess.Popen(self.command('report'), env=dict(self.env, PYTHONPATH=str(shim),
                                 REPORT_WRITE_STARTED=str(held), RELEASE_REPORT_WRITE=str(release)),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop, child)
        try:
            self.wait_for(held.exists)
            self.assertEqual(self.latest()['state'], 'waiting-for-lock')
        finally:
            release.touch()
        self.assertEqual(child.wait(timeout=10), 0)
        self.assertEqual(self.latest()['state'], 'passed')

    def test_old_bundle_is_rejected_when_current_scheme_no_longer_produces_it(self):
        self.assertEqual(self.invoke('first').returncode, 0)
        workspace = self.latest()['workspace']
        moved = self.invoke('moved', env=dict(self.env, PRODUCT_DIRECTORY='ZZ-current', BUNDLE_PAYLOAD='current moved plugin'))
        self.assertEqual(moved.returncode, 0, moved.stdout + moved.stderr)
        self.assertEqual((self.root / 'moved/Packages/example.mactoolsplugin/Example.bundle/payload').read_text(), 'current moved plugin')
        self.assertEqual(self.latest()['workspace'], workspace)
        result = self.invoke('renamed', env=dict(self.env, PRODUCT_NAME='Renamed.bundle'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.latest()['state'], 'failed')
        self.assertEqual(self.latest()['workspace'], workspace)
        self.assertFalse((self.root / 'renamed/Packages/example.mactoolsplugin').exists())

    def test_terminal_hangup_stops_packaging_and_finalizes_failure(self):
        held, release = self.root / 'copy-started', self.root / 'copy-release'
        console = self.root / 'hangup.log'
        with console.open('wb') as stream:
            child = subprocess.Popen(self.command('cancelled'), env=dict(self.env, HOLD_COPY=str(held), RELEASE_COPY=str(release)),
                                     stdout=stream, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop, child)
        try:
            self.wait_for(held.exists)
            child.send_signal(signal.SIGHUP)
            self.assertEqual(child.wait(timeout=10), 129, console.read_text())
            record = self.latest()
            self.assertEqual((record['state'], record['exit_code']), ('failed', 129))
            self.assertEqual(self.invoke('following').returncode, 0)
        finally:
            release.touch()

    def test_external_cache_and_output_overrides_are_rejected_before_compile(self):
        for changes in [{'MACTOOLS_PLUGIN_CACHE_ROOT': '/Volumes/MacTools-deferred-cache'},
                        {'OBJROOT': str(self.root / 'unmanaged')}]:
            result = self.invoke('rejected', env=dict(self.env, **changes))
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse((self.root / 'calls').exists())

    def test_misconfigured_overlapping_cache_is_preserved_before_package_reset(self):
        cache = self.root / 'output/Packages/compiler'
        cache.mkdir(parents=True)
        marker = cache / 'compiler-output'
        marker.write_text('preserve')
        result = self.invoke('output', env=dict(self.env, MACTOOLS_PLUGIN_CACHE_ROOT=str(cache)))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(marker.read_text(), 'preserve')
        self.assertFalse((self.root / 'calls').exists())


if __name__ == '__main__':
    unittest.main()
