#!/usr/bin/env python3
"""Own a reusable compiler workspace until local plugin packaging has finished."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import uuid

REPO = Path(__file__).resolve().parents[2]
OUTPUT_SETTINGS = ('OBJROOT', 'SYMROOT', 'CONFIGURATION_BUILD_DIR', 'CONFIGURATION_TEMP_DIR',
                   'PROJECT_TEMP_DIR', 'SHARED_PRECOMPS_DIR', 'CLANG_MODULE_CACHE_PATH',
                   'SWIFT_MODULE_CACHE_PATH', 'XCODE_XCCONFIG_FILE')
INPUT_SETTINGS = ('ARCHS', 'EXCLUDED_ARCHS', 'ONLY_ACTIVE_ARCH', 'SDKROOT', 'SWIFT_VERSION',
                  'TOOLCHAINS', 'SWIFT_EXEC', 'CC', 'CXX', 'LD', 'ENABLE_TESTABILITY',
                  'SWIFT_OPTIMIZATION_LEVEL', 'GCC_OPTIMIZATION_LEVEL',
                  'OTHER_SWIFT_FLAGS', 'OTHER_CFLAGS', 'OTHER_CPLUSPLUSFLAGS', 'OTHER_LDFLAGS',
                  'SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'GCC_PREPROCESSOR_DEFINITIONS',
                  'DEVELOPMENT_TEAM', 'CODE_SIGN_IDENTITY', 'CODE_SIGNING_ALLOWED',
                  'CODE_SIGNING_REQUIRED', 'MACTOOLS_PLUGIN_CACHE_VARIANT')


def internal_path(value):
    path = Path(value).expanduser()
    for candidate in (path.absolute(), path.resolve()):
        if candidate == Path('/Volumes') or Path('/Volumes') in candidate.parents:
            raise ValueError('External storage is deferred; choose an internal path.')
    return path.resolve()


def query(*command):
    return subprocess.check_output(command, text=True).strip()


def signal_group(pid, signum):
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Teardown can race an empty group on macOS. Never ignore an EPERM with live members.
        rows = subprocess.check_output(['/bin/ps', '-axo', 'pgid=,stat='], text=True)
        for line in rows.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == str(pid) and not parts[1].startswith('Z'):
                raise


def storage_paths(output_dir):
    cache = internal_path(os.environ.get('MACTOOLS_PLUGIN_CACHE_ROOT',
                                         str(Path.home() / 'Library/Caches/MacTools/PluginBuilds')))
    output = internal_path(output_dir)
    if cache == output or cache in output.parents or output in cache.parents:
        raise ValueError('Plugin packages/reports and compiler cache must have separate roots.')
    return cache, output


def run(args):
    overrides = [name for name in OUTPUT_SETTINGS if os.environ.get(name)]
    if overrides:
        raise ValueError('Compiler output overrides are unmanaged: ' + ', '.join(overrides))
    cache, output = storage_paths(args.output_dir)
    executable = shutil.which(args.xcodebuild)
    if executable is None:
        raise ValueError('xcodebuild executable not found: ' + args.xcodebuild)
    identity = dict(checkout=str(REPO), source=str(Path(args.source_dir).resolve()),
                    configuration=args.configuration, destination=args.destination,
                    unsigned=args.unsigned_build, host_architecture=platform.machine(),
                    developer=os.environ.get('DEVELOPER_DIR') or query('xcode-select', '-p'),
                    xcodebuild=str(Path(executable).resolve()), xcode_version=query(executable, '-version'),
                    sdk_build=query('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'),
                    settings={name: os.environ[name] for name in INPUT_SETTINGS if name in os.environ})
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:24]
    fresh = os.environ.get('MACTOOLS_PLUGIN_FRESH_BUILD') == '1'
    workspace = cache / (key + ('-fresh-' + uuid.uuid4().hex[:8] if fresh else ''))
    report = output / 'BuildReports' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
    report.mkdir(parents=True, exist_ok=False)
    workspace.mkdir(parents=True, exist_ok=True)
    temporary = workspace / 'Temporary'
    temporary.mkdir(exist_ok=True)
    env = dict(os.environ, MACTOOLS_PLUGIN_CACHE_CHECKOUT=str(REPO),
               MACTOOLS_PLUGIN_DERIVED_ROOT=str(workspace / 'DerivedData'),
               MACTOOLS_PLUGIN_BUILD_REPORT=str(report), TMPDIR=str(temporary) + '/')
    command = ['/bin/bash', str(REPO / 'scripts/plugins/build-local-plugins.sh'), *args.arguments]
    record = dict(identity=identity, cache_key=key, workspace=str(workspace), report=str(report),
                  command=command, fresh=fresh, state='waiting-for-lock')

    def save():
        temporary_report = report / 'build.json.tmp'
        temporary_report.write_text(json.dumps(record, indent=2) + '\n')
        temporary_report.replace(report / 'build.json')

    save()
    print('Plugin build report: ' + str(report), flush=True)
    with (workspace / '.build.lock').open('a+') as lock:
        def cancel_wait(signum, frame):
            record.update(state='failed', exit_code=128 + signum)
            save()
            raise SystemExit(128 + signum)

        waiting = {sig: signal.signal(sig, cancel_wait) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                record['lock_contended'] = True
                save()
                fcntl.flock(lock, fcntl.LOCK_EX)
        finally:
            for sig, handler in waiting.items():
                signal.signal(sig, handler)
        record.update(state='running', started_at=datetime.now(timezone.utc).isoformat())
        save()
        child = None
        received = []

        def forward(signum, frame):
            received.append(signum)
            if child is not None:
                signal_group(child.pid, signum)

        previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            with (report / 'build.log').open('wb') as log:
                child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                                         start_new_session=True, pass_fds=(lock.fileno(),))
                if received:
                    forward(received[-1], None)
                code = child.wait()
        except OSError as error:
            code = 2
            record['error'] = str(error)
        finally:
            if child is not None:
                # A failed/cancelled shell must leave no background compiler writers.
                signal_group(child.pid, signal.SIGKILL)
                child.wait()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        code = 128 + received[-1] if received else (128 - code if code < 0 else code)
        record.update(state='passed' if code == 0 else 'failed', exit_code=code,
                      finished_at=datetime.now(timezone.utc).isoformat())
        save()
    try:
        print((report / 'build.log').read_text(errors='replace'), end='', flush=True)
    except BrokenPipeError:
        pass
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--configuration', required=True)
    parser.add_argument('--destination', default='')
    parser.add_argument('--xcodebuild', required=True)
    parser.add_argument('--unsigned-build', action='store_true')
    parser.add_argument('--check-paths', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.arguments[:1] == ['--']:
        args.arguments = args.arguments[1:]
    try:
        if args.check_paths:
            storage_paths(args.output_dir)
            sys.exit(0)
        sys.exit(run(args))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('Plugin build cache: ' + str(error), file=sys.stderr)
        sys.exit(2)
