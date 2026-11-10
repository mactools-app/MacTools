#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
FIXTURE_TOOL="$SCRIPT_DIR/MacToolsE2EFixture.swift"
APP_CONTROLLER_TOOL="$SCRIPT_DIR/MacToolsE2EAppController.swift"
KEY_SENDER_TOOL="$SCRIPT_DIR/MacToolsE2EKeySender.swift"
CAPTURE_RECT_TOOL="$SCRIPT_DIR/MacToolsE2ECaptureRect.swift"
PRIVACY_HELPER_SOURCE="$SCRIPT_DIR/MacToolsE2EPrivacyHelper.swift"
PRIVACY_RECORDER_SOURCE="$SCRIPT_DIR/MacToolsE2ERecorder.swift"
SCENARIO_MANIFEST="$SCRIPT_DIR/scenarios.json"
HARNESS_PATH="$SCRIPT_DIR/mactools-e2e.sh"
APP_PATH="${MACTOOLS_E2E_APP_PATH:-$HOME/Applications/MacTools Dev.app}"
PLUGIN_INSTALL_DIR="${MACTOOLS_E2E_PLUGIN_DIR:-$HOME/Library/Application Support/MacTools Dev/Plugins/Installed}"
PLUGIN_CATALOG_PATH="${MACTOOLS_E2E_PLUGIN_CATALOG_PATH:-$REPO_ROOT/build/LocalPlugins/catalog.dev.json}"
ARTIFACT_ROOT="${MACTOOLS_E2E_ARTIFACT_ROOT:-$REPO_ROOT/build/E2EArtifacts}"
BUILT_APP_PATH="$REPO_ROOT/build/DerivedData/Build/Products/Debug/${APP_PATH:t}"
PYTHON3="${PYTHON3:-/usr/bin/python3}"
FFMPEG="${MACTOOLS_E2E_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
FFPROBE="${MACTOOLS_E2E_FFPROBE:-${FFMPEG:h}/ffprobe}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    E2E_DEVELOPER_DIR="$DEVELOPER_DIR"
elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    E2E_DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
else
    E2E_DEVELOPER_DIR="$(xcode-select -p)"
fi

usage() {
    print -r -- "Usage: $0 <command> [arguments]"
    print -r -- ""
    print -r -- "Commands:"
    print -r -- "  preflight [output.json]               Verify stable app, signing, plugins, and tools"
    print -r -- "  prepare                               Back up preferences, seed safe fixtures, and launch"
    print -r -- "  upgrade <session-dir>                 Reset checkpoints and install the latest fixture"
    print -r -- "  reseed <session-dir>                  Reset fixture state without replacing its backup"
    print -r -- "  resume <session-dir>                  Revalidate and reopen a prepared session"
    print -r -- "  rebuild <session-dir> [--dry-run]     Rebuild and replace the stable signed app"
    print -r -- "  audit <session-dir>                   Save and validate fixture state"
    print -r -- "  checkpoint <session-dir> <name> <pass|fail|pending> [detail]"
    print -r -- "  shortcut <session-dir> <open-settings|action-grid|dashboard|safe-workflow> [--dry-run]"
    print -r -- "  pointer-click <session-dir> <reference-width> <reference-height> <x> <y> [--dry-run]"
    print -r -- "  input-select-all <session-dir> [--dry-run]"
    print -r -- "  input-text <session-dir> <text> [--dry-run]"
    print -r -- "  input-key <session-dir> <command-k|return|escape> [--dry-run]"
    print -r -- "  privacy-helper <session-dir> <primary|secondary> [--dry-run]"
    print -r -- "  record <session-dir> [seconds] [--dry-run]"
    print -r -- "  record-pack <session-dir> <pack-id> [seconds] [--dry-run]"
    print -r -- "  wait-recording-ready <session-dir> [label] [seconds]"
    print -r -- "  start-recording <session-dir> [label]"
    print -r -- "  stop-recording <session-dir> [label]"
    print -r -- "  verify-code <session-dir> [--dry-run]   Run migration and injected-trackpad suites"
    print -r -- "  scenarios [pack-id]                   Print all scenario packs or one pack"
    print -r -- "  collect <session-dir>                 Build report.json and diagnostic artifacts"
    print -r -- "  restore <session-dir>                 Restore preferences and relaunch the app"
    print -r -- "  self-test                             Validate the fixture tool in an isolated domain"
}

require_app() {
    if [[ ! -d "$APP_PATH" ]]; then
        print -u2 -r -- "error: stable app not found at $APP_PATH"
        return 1
    fi
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

app_bundle_identifier() {
    plist_value "$APP_PATH/Contents/Info.plist" CFBundleIdentifier
}

app_executable() {
    local executable_name
    executable_name="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleExecutable)"
    print -r -- "$APP_PATH/Contents/MacOS/$executable_name"
}

app_version() {
    plist_value "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString
}

app_build() {
    plist_value "$APP_PATH/Contents/Info.plist" CFBundleVersion
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

sha256_tree() {
    local root="$1"
    [[ -d "$root" ]] || {
        print -u2 -r -- "error: provenance directory is missing at $root"
        return 1
    }
    "$PYTHON3" - "$root" <<'PY'
import hashlib
import os
import sys

root = os.path.realpath(sys.argv[1])
digest = hashlib.sha256()
for directory, names, files in os.walk(root, followlinks=False):
    names.sort()
    files.sort()
    for name in names + files:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root).replace(os.sep, "/")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if os.path.islink(path):
            digest.update(b"L\0")
            digest.update(os.readlink(path).encode("utf-8"))
        elif os.path.isdir(path):
            digest.update(b"D\0")
        else:
            digest.update(b"F\0")
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        digest.update(b"\0")
print(digest.hexdigest())
PY
}

source_tree_sha256() {
    "$PYTHON3" - "$REPO_ROOT" "$@" <<'PY'
import hashlib
import os
import subprocess
import sys

root = os.path.realpath(sys.argv[1])
output_dirs = sys.argv[2:]
git_ls_files = ["git", "-C", root, "ls-files", "-z"]
if output_dirs:
    tracked = subprocess.check_output([*git_ls_files, "--cached"])
    untracked = subprocess.check_output([
        *git_ls_files, "--others", "--exclude-standard", "--", ".",
        *(f":(exclude,top,literal){directory}" for directory in output_dirs),
    ])
    paths = (tracked + untracked).split(b"\0")
else:
    paths = subprocess.check_output([
        *git_ls_files, "--cached", "--others", "--exclude-standard",
    ]).split(b"\0")
digest = hashlib.sha256()
for raw in sorted(path for path in paths if path):
    relative = raw.decode("utf-8", "surrogateescape")
    path = os.path.join(root, relative)
    digest.update(raw)
    digest.update(b"\0")
    if not os.path.exists(path) and not os.path.islink(path):
        digest.update(b"R\0")
    elif os.path.islink(path):
        digest.update(b"L\0")
        digest.update(os.readlink(path).encode("utf-8", "surrogateescape"))
    else:
        digest.update(b"F\0")
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

app_code_directory_hash() {
    codesign -dv --verbose=4 "$APP_PATH" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'
}

source_commit() {
    git -C "$REPO_ROOT" rev-parse --verify HEAD
}

source_dirty() {
    local changes
    if (( $# > 0 )); then
        changes="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" || return 1
        if [[ -z "$changes" ]]; then
            local -a exclusions
            local directory
            for directory in "$@"; do
                exclusions+=(":(exclude,top,literal)$directory")
            done
            changes="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard \
                -- . "${exclusions[@]}")" || return 1
        fi
    else
        changes="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" || return 1
    fi
    if [[ -n "$changes" ]]; then
        print -r -- true
    else
        print -r -- false
    fi
}

debug_build_path() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" make -s --no-print-directory -C "$REPO_ROOT" "$1"
}

source_output_directory() {
    local build_directory="${1:A}"
    if [[ "$build_directory" == "$REPO_ROOT" ]]; then
        print -u2 -r -- "error: Derived Data cannot be the checkout root"
        return 1
    fi
    [[ "$build_directory" == "$REPO_ROOT/"* ]] || return 0

    local relative_directory="${build_directory#"$REPO_ROOT/"}"
    local tracked_files
    tracked_files="$(git -C "$REPO_ROOT" ls-files -- ":(top,literal)$relative_directory")" || return 1
    [[ -z "$tracked_files" ]] || {
        print -u2 -r -- "error: Derived Data must use a dedicated directory without tracked files: $build_directory"
        return 1
    }
    print -r -- "$relative_directory"
}

session_source_output_directories() {
    "$PYTHON3" - "$1" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    metadata = plistlib.load(handle)
for directory in metadata.get("sourceOutputDirectories", [metadata.get("sourceOutputDirectory")]):
    if directory:
        sys.stdout.buffer.write(os.fsencode(directory) + b"\0")
PY
}

extension_bundle_identifier() {
    local extension_plist="$APP_PATH/Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
    [[ -f "$extension_plist" ]] || return 0
    plist_value "$extension_plist" CFBundleIdentifier
}

fixture_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$FIXTURE_TOOL" "$@"
}

app_controller_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$APP_CONTROLLER_TOOL" "$@"
}

key_sender_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$KEY_SENDER_TOOL" "$@"
}

capture_rect_tool() {
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swift "$CAPTURE_RECT_TOOL" "$@"
}

privacy_recorder_binary() {
    local session_dir="$1"
    print -r -- "$session_dir/privacy-recorder/MacToolsE2ERecorder"
}

build_privacy_recorder() {
    local session_dir="$1"
    [[ -f "$PRIVACY_RECORDER_SOURCE" ]] || {
        print -u2 -r -- "error: application-filtered recorder source is unavailable"
        return 1
    }
    local binary
    binary="$(privacy_recorder_binary "$session_dir")"
    mkdir -p "${binary:h}"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -parse-as-library -suppress-warnings \
        -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
        "$PRIVACY_RECORDER_SOURCE" -o "$binary"
    /usr/bin/codesign --force --sign - "$binary"
}

ensure_privacy_recorder() {
    local session_dir="$1"
    local binary
    binary="$(privacy_recorder_binary "$session_dir")"
    if [[ ! -x "$binary" || "$PRIVACY_RECORDER_SOURCE" -nt "$binary" ]]; then
        build_privacy_recorder "$session_dir"
    fi
}

privacy_recorder_tool() {
    local session_dir="$1"
    shift
    "$(privacy_recorder_binary "$session_dir")" "$@"
}

input_driver_binary() {
    local session_dir="$1"
    print -r -- "$session_dir/input-driver/MacToolsE2EInputDriver"
}

build_input_driver() {
    local session_dir="$1"
    local binary
    binary="$(input_driver_binary "$session_dir")"
    mkdir -p "${binary:h}"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -framework ApplicationServices -framework CoreGraphics \
        "$KEY_SENDER_TOOL" -o "$binary"
    /usr/bin/codesign --force --sign - "$binary"
}

ensure_input_driver() {
    local session_dir="$1"
    local binary
    binary="$(input_driver_binary "$session_dir")"
    if [[ ! -x "$binary" || "$KEY_SENDER_TOOL" -nt "$binary" ]]; then
        build_input_driver "$session_dir"
    fi
}

input_driver_tool() {
    local session_dir="$1"
    shift
    "$(input_driver_binary "$session_dir")" "$@"
}

privacy_helper_app_path() {
    local session_dir="$1"
    local variant="$2"
    print -r -- "$session_dir/privacy-helpers/MacTools E2E ${variant:u} Helper.app"
}

privacy_helper_executable_name() {
    case "$1" in
        primary) print -r -- "MacToolsE2EPrimaryHelper" ;;
        secondary) print -r -- "MacToolsE2ESecondaryHelper" ;;
        backdrop) print -r -- "MacToolsE2EBackdropHelper" ;;
        *)
            print -u2 -r -- "error: unknown privacy helper variant $1"
            return 1
            ;;
    esac
}

privacy_helper_executable_path() {
    local session_dir="$1"
    local variant="$2"
    print -r -- "$(privacy_helper_app_path "$session_dir" "$variant")/Contents/MacOS/$(privacy_helper_executable_name "$variant")"
}

launch_privacy_helper_process() {
    local session_dir="$1"
    local variant="$2"
    shift 2
    local executable
    executable="$(privacy_helper_executable_path "$session_dir" "$variant")"
    [[ -x "$executable" ]] || {
        print -u2 -r -- "error: privacy helper executable is unavailable at $executable"
        return 1
    }
    "$executable" "$@" >/dev/null 2>&1 &!
}

build_privacy_helpers() {
    local session_dir="$1"
    [[ -f "$PRIVACY_HELPER_SOURCE" ]] || {
        print -u2 -r -- "error: privacy-safe helper source is unavailable"
        return 1
    }
    local helper_root="$session_dir/privacy-helpers"
    local executable="$helper_root/MacToolsE2EPrivacyHelper"
    mkdir -p "$helper_root"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -parse-as-library -framework AppKit "$PRIVACY_HELPER_SOURCE" -o "$executable"

    local variant app bundle_id title accent executable_name
    for variant in primary secondary backdrop; do
        app="$(privacy_helper_app_path "$session_dir" "$variant")"
        if [[ "$variant" == primary ]]; then
            bundle_id="com.jennymedia.mactools.e2e-helper.primary"
            title="MacTools E2E Primary Helper"
            accent="orange"
        elif [[ "$variant" == secondary ]]; then
            bundle_id="com.jennymedia.mactools.e2e-helper.secondary"
            title="MacTools E2E Secondary Helper"
            accent="blue"
        else
            bundle_id="com.jennymedia.mactools.e2e-helper.backdrop"
            title="MacTools E2E Privacy Backdrop"
            accent="blue"
        fi
        executable_name="$(privacy_helper_executable_name "$variant")"
        mkdir -p "$app/Contents/MacOS"
        /usr/bin/ditto "$executable" "$app/Contents/MacOS/$executable_name"
        "$PYTHON3" - \
            "$app/Contents/Info.plist" "$bundle_id" "$title" "$accent" "$executable_name" <<'PY'
import plistlib
import sys

path, bundle_id, title, accent, executable_name = sys.argv[1:]
payload = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": title,
    "CFBundleExecutable": executable_name,
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": title,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "14.0",
    "MacToolsE2EAccent": accent,
    "MacToolsE2ETitle": title,
    "NSHighResolutionCapable": True,
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle)
PY
        /usr/bin/codesign --force --sign - "$app"
        "$LSREGISTER" -f "$app"
    done
}

ensure_privacy_helpers() {
    local session_dir="$1"
    local primary secondary backdrop
    primary="$(privacy_helper_executable_path "$session_dir" primary)"
    secondary="$(privacy_helper_executable_path "$session_dir" secondary)"
    backdrop="$(privacy_helper_executable_path "$session_dir" backdrop)"
    if [[ ! -x "$primary" || ! -x "$secondary" || ! -x "$backdrop" ]]; then
        build_privacy_helpers "$session_dir"
        return
    fi
    "$LSREGISTER" -f "$(privacy_helper_app_path "$session_dir" primary)"
    "$LSREGISTER" -f "$(privacy_helper_app_path "$session_dir" secondary)"
    "$LSREGISTER" -f "$(privacy_helper_app_path "$session_dir" backdrop)"
}

recording_visibility_state_path() {
    local session_dir="$1"
    print -r -- "$session_dir/privacy-recorder/hidden-application-pids.txt"
}

restore_recording_visibility() {
    local session_dir="$1"
    local state_path executable
    state_path="$(recording_visibility_state_path "$session_dir")"
    executable="$(privacy_helper_executable_path "$session_dir" backdrop)"
    if [[ -s "$state_path" && -x "$executable" ]]; then
        "$executable" --restore-visibility "$state_path"
    fi
    rm -f -- "$state_path"
}

stop_privacy_helpers() {
    local session_dir="$1"
    local variant executable
    local cleanup_failed=false
    for variant in primary secondary backdrop; do
        executable="$(privacy_helper_executable_path "$session_dir" "$variant")"
        if [[ -x "$executable" ]] && ! "$executable" \
            --terminate-running-copies "$executable" >/dev/null 2>&1; then
            cleanup_failed=true
        fi
    done
    sleep 0.25
    [[ "$cleanup_failed" == false ]] \
        || print -u2 -r -- "warning: privacy helper required forced termination"
    restore_recording_visibility "$session_dir"
    return 0
}

matching_pids() {
    local executable
    executable="$(app_executable)"
    pgrep -f -x "$executable" || true
}

single_executable_pid() {
    local executable="$1"
    local label="$2"
    local output
    output="$(/bin/ps -axo pid=,command= | awk -v executable="$executable" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
            if ($0 == executable || index($0, executable " ") == 1) print pid
        }
    ')"
    if [[ -z "$output" ]] || [[ "$(print -r -- "$output" | wc -l | tr -d ' ')" != 1 ]]; then
        print -u2 -r -- "error: expected exactly one $label process before recording"
        return 1
    fi
    print -r -- "${output%%$'\n'*}"
}

matching_built_pids() {
    local bundle_path="${1:-$BUILT_APP_PATH}"
    local executable_name executable_pattern
    [[ -f "$bundle_path/Contents/Info.plist" ]] || return 0
    executable_name="$(plist_value "$bundle_path/Contents/Info.plist" CFBundleExecutable 2>/dev/null)" || return 0
    [[ -n "$executable_name" && "$executable_name" != */* ]] || return 0
    executable_pattern="$(print -r -- "$bundle_path/Contents/MacOS/$executable_name" \
        | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    pgrep -f -x "$executable_pattern" || true
}

conflicting_built_pids() {
    local -aU build_app_paths
    build_app_paths=("$BUILT_APP_PATH" "${BUILT_APP_PATH:A}")
    local candidate
    for candidate in "$@"; do
        [[ -n "$candidate" ]] || continue
        build_app_paths+=("$candidate" "${candidate:A}")
    done
    local bundle_path
    for bundle_path in "${build_app_paths[@]}"; do
        matching_built_pids "$bundle_path"
    done
}

stop_app() {
    local output
    output="$(matching_pids)"
    [[ -n "$output" ]] || return 0

    local -a pids
    pids=("${(@f)output}")
    local pid
    for pid in "${pids[@]}"; do
        app_controller_tool terminate "$pid" || true
    done

    local attempt
    for attempt in {1..50}; do
        [[ -z "$(matching_pids)" ]] && return 0
        sleep 0.1
    done

    print -u2 -r -- "warning: MacTools Dev ignored the graceful quit request; falling back to SIGTERM"
    output="$(matching_pids)"
    [[ -z "$output" ]] || /bin/kill -TERM -- "${(@f)output}"
    for attempt in {1..50}; do
        [[ -z "$(matching_pids)" ]] && return 0
        sleep 0.1
    done
    print -u2 -r -- "error: MacTools Dev did not terminate after SIGTERM fallback"
    return 1
}

stop_built_app() {
    local output
    output="$(matching_built_pids)"
    [[ -n "$output" ]] || return 0

    local -a pids
    pids=("${(@f)output}")
    local pid
    for pid in "${pids[@]}"; do
        app_controller_tool terminate "$pid" || true
    done

    local attempt
    for attempt in {1..50}; do
        [[ -z "$(matching_built_pids)" ]] && return 0
        sleep 0.1
    done

    print -u2 -r -- "warning: Derived Data MacTools test host ignored the graceful quit request; falling back to SIGTERM"
    output="$(matching_built_pids)"
    [[ -z "$output" ]] || /bin/kill -TERM -- "${(@f)output}"
    for attempt in {1..50}; do
        [[ -z "$(matching_built_pids)" ]] && return 0
        sleep 0.1
    done
    print -u2 -r -- "error: Derived Data MacTools test host did not terminate after SIGTERM fallback"
    return 1
}

restore_stable_launch_services_registration() {
    [[ -x "$LSREGISTER" ]] || {
        print -u2 -r -- "error: lsregister is unavailable at $LSREGISTER"
        return 1
    }
    if [[ -d "$BUILT_APP_PATH" ]]; then
        "$LSREGISTER" -u "$BUILT_APP_PATH" >/dev/null 2>&1 || true
    fi
    "$LSREGISTER" -f "$APP_PATH" >/dev/null
}

restore_stable_app_after_code_verification() {
    stop_built_app || true
    restore_stable_launch_services_registration || true
    if [[ -z "$(matching_pids)" ]]; then
        /usr/bin/open -n -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    fi
}

expected_team_identifier() {
    if [[ -n "${MACTOOLS_E2E_TEAM_ID:-}" ]]; then
        print -r -- "$MACTOOLS_E2E_TEAM_ID"
        return
    fi
    local config="$REPO_ROOT/LocalConfig.xcconfig"
    [[ -f "$config" ]] || return 0
    awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{value=$2; gsub(/[[:space:]]/, "", value); print value; exit}' "$config"
}

write_preflight_json() {
    local output_path="$1"
    local bundle_id="$2"
    local team_id="$3"
    local expected_team_id="$4"
    local authority="$5"
    local plugin_count="$6"
    local process_count="$7"
    local event_posting_access="$8"
    local conflicting_process_count="$9"
    local trackpad_listener_lease_owned="${10}"
    local trackpad_listener_owner_pids="${11}"
    local trackpad_listener_other_owner_pids="${12}"
    local passed="${13}"

    mkdir -p "${output_path:h}"
    "$PYTHON3" - "$output_path" "$APP_PATH" "$bundle_id" "$team_id" "$expected_team_id" \
        "$authority" "$plugin_count" "$process_count" "$event_posting_access" \
        "$conflicting_process_count" "$trackpad_listener_lease_owned" \
        "$trackpad_listener_owner_pids" "$trackpad_listener_other_owner_pids" \
        "$FFMPEG" "$FFPROBE" "$passed" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    output_path,
    app_path,
    bundle_id,
    team_id,
    expected_team_id,
    authority,
    plugin_count,
    process_count,
    event_posting_access,
    conflicting_process_count,
    trackpad_listener_lease_owned,
    trackpad_listener_owner_pids,
    trackpad_listener_other_owner_pids,
    transcoder,
    media_probe,
    passed,
) = sys.argv[1:]
listener_owner_pids = [
    int(value) for value in trackpad_listener_owner_pids.splitlines() if value.isdigit()
]
listener_other_owner_pids = [
    int(value) for value in trackpad_listener_other_owner_pids.splitlines() if value.isdigit()
]
listener_owned = trackpad_listener_lease_owned == "true"
permission_state = (
    "blocked-by-other-process"
    if listener_other_owner_pids
    else ("granted" if listener_owned else "unverified")
)
payload = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "passed": passed == "true",
    "appPath": app_path,
    "bundleIdentifier": bundle_id,
    "teamIdentifier": team_id,
    "expectedTeamIdentifier": expected_team_id or None,
    "authority": authority,
    "installedPluginCount": int(plugin_count),
    "matchingProcessCount": int(process_count),
    "derivedDataProcessCount": int(conflicting_process_count),
    "eventPostingAccess": event_posting_access == "true",
    "recorder": "scripts/e2e/MacToolsE2ERecorder.swift",
    "recorderPrivacyFilter": "application-allowlist",
    "recorderEnvironmentPreparation": "hide-and-restore-unrelated-regular-apps",
    "transcoder": transcoder,
    "mediaProbe": media_probe,
    "permissionState": permission_state,
    "permissionEvidence": {
        "trackpadListenerLeaseOwnedByStableApp": listener_owned,
        "trackpadListenerLeaseOwnerPIDs": listener_owner_pids,
        "trackpadListenerLeaseOwnedByOtherProcesses": bool(listener_other_owner_pids),
        "trackpadListenerLeaseOtherOwnerPIDs": listener_other_owner_pids,
        "meaning": (
            "Another process owns the one global Trackpad Gestures listener lease."
            if listener_other_owner_pids
            else (
                "The active Trackpad Gestures listener starts only after MacTools observes both "
                "Accessibility and Input Monitoring permission."
                if listener_owned
                else "No active Trackpad Gestures listener was observed; this does not prove denial."
            )
        ),
    },
}
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

preflight() {
    require_app
    local output_path="${1:-$ARTIFACT_ROOT/preflight-latest.json}"
    local recorded_app_path="${2:-}"
    local configured_app_path="${3:-}"
    if [[ -z "$configured_app_path" ]]; then
        configured_app_path="$(debug_build_path print-debug-app-path)" || return 1
    fi
    local bundle_id
    bundle_id="$(app_bundle_identifier)"

    local signature_output
    signature_output="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
    local team_id authority expected_team
    team_id="$(print -r -- "$signature_output" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    authority="$(print -r -- "$signature_output" | awk -F= '/^Authority=Apple Development:/{print $2; exit}')"
    expected_team="$(expected_team_identifier)"

    local plugin_count=0
    if [[ -d "$PLUGIN_INSTALL_DIR" ]]; then
        plugin_count="$(find "$PLUGIN_INSTALL_DIR" -maxdepth 1 -type d -name '*.mactoolsplugin' | wc -l | tr -d ' ')"
    fi
    local process_count=0
    local process_output
    process_output="$(matching_pids)"
    if [[ -n "$process_output" ]]; then
        process_count="$(print -r -- "$process_output" | wc -l | tr -d ' ')"
    fi
    local conflicting_process_count=0
    local conflicting_process_output
    conflicting_process_output="$(conflicting_built_pids "$configured_app_path" "$recorded_app_path")"
    if [[ -n "$conflicting_process_output" ]]; then
        conflicting_process_count="$(print -r -- "$conflicting_process_output" | wc -l | tr -d ' ')"
    fi
    local event_posting_access=false
    if key_sender_tool check >/dev/null 2>&1; then
        event_posting_access=true
    fi
    local trackpad_listener_lease_owned=false
    local listener_lock="${TMPDIR:-/tmp}"
    listener_lock="${listener_lock%/}/mactools.trackpad-gestures.listener.lock"
    local listener_owners=""
    local listener_other_owners=""
    if [[ -f "$listener_lock" ]]; then
        listener_owners="$(/usr/sbin/lsof -t -- "$listener_lock" 2>/dev/null || true)"
        local owner_pid
        for owner_pid in "${(@f)listener_owners}"; do
            [[ -n "$owner_pid" ]] || continue
            if [[ -n "$process_output" ]] \
                && print -r -- "$process_output" | grep -q -x "$owner_pid"; then
                trackpad_listener_lease_owned=true
            else
                listener_other_owners+="${listener_other_owners:+$'\n'}$owner_pid"
            fi
        done
    fi

    local -a failures
    failures=()
    codesign --verify --deep --strict "$APP_PATH" 2>/dev/null || failures+=("strict code-signature verification failed")
    [[ -n "$team_id" ]] || failures+=("Apple Development team identifier is missing")
    [[ -n "$authority" ]] || failures+=("Apple Development signing authority is missing")
    if [[ -n "$expected_team" && "$team_id" != "$expected_team" ]]; then
        failures+=("team identifier $team_id does not match expected $expected_team")
    fi
    [[ "$APP_PATH" != *"/build/"* ]] || failures+=("app path is not stable")
    (( plugin_count > 0 )) || failures+=("no installed Debug plugin packages were found")
    (( process_count <= 1 )) || failures+=("more than one stable-path app instance is running")
    (( conflicting_process_count == 0 )) \
        || failures+=("a MacTools app is still running from Derived Data")
    [[ -z "$listener_other_owners" ]] \
        || failures+=("the global trackpad listener lease is owned by another process: ${listener_other_owners//$'\n'/,}")
    [[ -f "$CAPTURE_RECT_TOOL" ]] || failures+=("private capture rectangle helper is unavailable")
    [[ -f "$PRIVACY_RECORDER_SOURCE" ]] || failures+=("application-filtered recorder is unavailable")
    [[ -x "$FFMPEG" ]] || failures+=("ffmpeg is unavailable at $FFMPEG")
    [[ -x "$FFPROBE" ]] || failures+=("ffprobe is unavailable at $FFPROBE")

    local passed=true
    (( ${#failures[@]} == 0 )) || passed=false
    write_preflight_json \
        "$output_path" "$bundle_id" "$team_id" "$expected_team" "$authority" \
        "$plugin_count" "$process_count" "$event_posting_access" \
        "$conflicting_process_count" "$trackpad_listener_lease_owned" \
        "$listener_owners" "$listener_other_owners" "$passed"

    print -r -- "App: $APP_PATH"
    print -r -- "Bundle: $bundle_id"
    print -r -- "Team: $team_id"
    print -r -- "Authority: $authority"
    print -r -- "Installed plugins: $plugin_count"
    print -r -- "Running instances: $process_count"
    print -r -- "Derived Data test hosts: $conflicting_process_count"
    print -r -- "Synthetic shortcut access: $event_posting_access"
    print -r -- "Trackpad listener permission evidence: $trackpad_listener_lease_owned"
    print -r -- "Report: $output_path"

    if [[ "$passed" != true ]]; then
        local failure
        for failure in "${failures[@]}"; do
            print -u2 -r -- "error: $failure"
        done
        return 1
    fi
}

domain_exists() {
    defaults read "$1" >/dev/null 2>&1
}

save_domain() {
    local domain="$1"
    local output="$2"
    if domain_exists "$domain"; then
        defaults export "$domain" "$output" >/dev/null
        return 0
    fi
    return 1
}

restore_domain() {
    local domain="$1"
    local existed="$2"
    local backup="$3"
    if [[ "$existed" == true ]]; then
        [[ -f "$backup" ]] || {
            print -u2 -r -- "error: missing preferences backup $backup"
            return 1
        }
        defaults import "$domain" "$backup" >/dev/null
    else
        defaults delete "$domain" >/dev/null 2>&1 || true
    fi
}

write_session_metadata() {
    local metadata="$1"
    local bundle_id="$2"
    local extension_id="$3"
    local had_preferences="$4"
    local had_extension_preferences="$5"

    plutil -create xml1 "$metadata"
    plutil -insert appPath -string "$APP_PATH" "$metadata"
    plutil -insert bundleIdentifier -string "$bundle_id" "$metadata"
    plutil -insert extensionBundleIdentifier -string "$extension_id" "$metadata"
    plutil -insert hadPreferences -bool "$had_preferences" "$metadata"
    plutil -insert hadExtensionPreferences -bool "$had_extension_preferences" "$metadata"
    plutil -insert preparedAt -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$metadata"
    plutil -insert preparedAtEpoch -integer "$(date '+%s')" "$metadata"
    write_session_provenance "$metadata" false
}

write_session_provenance() {
    local metadata="$1"
    local source_build_bound="${2:-false}"
    local configured_app_path="${3:-}"
    local -a output_dirs
    output_dirs=("${@:4}")
    local executable
    executable="$(app_executable)"
    [[ -f "$executable" ]] || {
        print -u2 -r -- "error: app executable is missing at $executable"
        return 1
    }

    local key
    [[ -d "$PLUGIN_INSTALL_DIR" ]] || {
        print -u2 -r -- "error: installed plugin directory is missing at $PLUGIN_INSTALL_DIR"
        return 1
    }
    [[ -f "$PLUGIN_CATALOG_PATH" ]] || {
        print -u2 -r -- "error: local plugin catalog is missing at $PLUGIN_CATALOG_PATH"
        return 1
    }

    for key in sourceCommit sourceDirty sourceTreeSHA256 sourceBuildBound sourceOutputDirectory sourceOutputDirectories builtAppPath appVersion appBuild appExecutableSHA256 appCodeDirectoryHash pluginPackageTreeSHA256 pluginCatalogSHA256; do
        plutil -remove "$key" "$metadata" >/dev/null 2>&1 || true
    done
    plutil -insert sourceCommit -string "$(source_commit)" "$metadata"
    plutil -insert sourceDirty -bool "$(source_dirty "${output_dirs[@]}")" "$metadata"
    plutil -insert sourceTreeSHA256 -string "$(source_tree_sha256 "${output_dirs[@]}")" "$metadata"
    plutil -insert sourceBuildBound -bool "$source_build_bound" "$metadata"
    if [[ -n "$configured_app_path" ]]; then
        local output_dirs_json
        output_dirs_json="$("$PYTHON3" -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${output_dirs[@]}")"
        plutil -insert sourceOutputDirectories -json "$output_dirs_json" "$metadata"
        plutil -insert builtAppPath -string "$configured_app_path" "$metadata"
    fi
    plutil -insert appVersion -string "$(app_version)" "$metadata"
    plutil -insert appBuild -string "$(app_build)" "$metadata"
    plutil -insert appExecutableSHA256 -string "$(sha256_file "$executable")" "$metadata"
    plutil -insert appCodeDirectoryHash -string "$(app_code_directory_hash)" "$metadata"
    plutil -insert pluginPackageTreeSHA256 -string "$(sha256_tree "$PLUGIN_INSTALL_DIR")" "$metadata"
    plutil -insert pluginCatalogSHA256 -string "$(sha256_file "$PLUGIN_CATALOG_PATH")" "$metadata"
}

write_pending_checkpoints() {
    local output="$1"
    "$PYTHON3" - "$output" "$SCENARIO_MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as handle:
    manifest = json.load(handle)
names = [
    name
    for pack in manifest["packs"]
    for name in pack["checkpoints"]
]
if len(names) != len(set(names)):
    raise SystemExit("scenario manifest contains duplicate checkpoint names")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({name: {"status": "pending", "detail": ""} for name in names}, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

print_scenarios() {
    local pack_id="${1:-}"
    "$PYTHON3" - "$SCENARIO_MANIFEST" "$pack_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
pack_id = sys.argv[2]
if not pack_id:
    print(json.dumps(manifest, indent=2, sort_keys=True))
    raise SystemExit(0)
for pack in manifest["packs"]:
    if pack["id"] == pack_id:
        print(json.dumps(pack, indent=2, sort_keys=True))
        raise SystemExit(0)
raise SystemExit(f"unknown scenario pack: {pack_id}")
PY
}

recording_start_route() {
    local pack_id="$1"
    "$PYTHON3" - "$SCENARIO_MANIFEST" "$pack_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for pack in manifest["packs"]:
    if pack["id"] == sys.argv[2]:
        print(pack.get("recordingStartRoute", "settings/features/automation"))
        raise SystemExit(0)
raise SystemExit(f"unknown scenario pack: {sys.argv[2]}")
PY
}

recording_marker_path() {
    local session_dir="${1:A}"
    local label="${2:-}"
    local marker="$3"
    local base_name="screencast"
    [[ -z "$label" ]] || base_name="screencast.$label"
    print -r -- "$session_dir/privacy-recorder/$base_name.$marker"
}

validate_recording_label() {
    local label="${1:-}"
    [[ -z "$label" || "$label" != *[^a-z0-9-]* ]] || {
        print -u2 -r -- "error: recording label must contain only lowercase letters, digits, and hyphens"
        return 1
    }
}

wait_recording_ready() {
    local session_dir="$1"
    local label="${2:-}"
    local timeout="${3:-15}"
    validate_recording_label "$label" || return 1
    validate_session_identity "$session_dir" || return 1
    [[ "$timeout" == <-> ]] && (( timeout >= 1 && timeout <= 60 )) || {
        print -u2 -r -- "error: ready timeout must be between 1 and 60 seconds"
        return 1
    }
    local ready_marker
    ready_marker="$(recording_marker_path "$session_dir" "$label" ready)"
    local attempt
    for (( attempt = 1; attempt <= timeout * 10; attempt++ )); do
        if [[ -f "$ready_marker" ]]; then
            print -r -- "recording-ready=$ready_marker"
            return 0
        fi
        sleep 0.1
    done
    print -u2 -r -- "error: recorder did not become ready within $timeout seconds"
    return 1
}

start_recording() {
    local session_dir="$1"
    local label="${2:-}"
    validate_recording_label "$label" || return 1
    validate_session_identity "$session_dir" || return 1
    local start_marker
    start_marker="$(recording_marker_path "$session_dir" "$label" start)"
    mkdir -p "${start_marker:h}"
    /usr/bin/touch "$start_marker"
    print -r -- "recording-start-requested=$start_marker"
}

stop_recording() {
    local session_dir="$1"
    local label="${2:-}"
    validate_recording_label "$label" || return 1
    validate_session_identity "$session_dir" || return 1
    local stop_marker
    stop_marker="$(recording_marker_path "$session_dir" "$label" stop)"
    mkdir -p "${stop_marker:h}"
    /usr/bin/touch "$stop_marker"
    print -r -- "recording-stop-requested=$stop_marker"
}

resume_session() {
    local session_dir="$1"
    validate_session_identity "$session_dir" || return 1

    ensure_privacy_helpers "$session_dir"
    preflight "$session_dir/preflight.json" "$(session_value "$session_dir" builtAppPath 2>/dev/null || true)"
    audit_session "$session_dir" >/dev/null
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"

    "$PYTHON3" - "$session_dir/ui-checkpoints.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    checkpoints = json.load(handle)
pending = sorted(name for name, item in checkpoints.items() if item["status"] != "pass")
print("Pending checkpoints: " + (", ".join(pending) if pending else "none"))
PY
    print -r -- "Recording command: $HARNESS_PATH record '$session_dir' 90"
    print -r -- "Restore command: $HARNESS_PATH restore '$session_dir'"
}

rebuild_session() {
    local session_dir="$1"
    local mode="${2:-}"
    validate_session_identity "$session_dir" true || return 1

    local expected_bundle_id rebuilt_app_path recorded_app_path build_directory output_dir recorded_output_dirs
    expected_bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    rebuilt_app_path="$(debug_build_path print-debug-app-path)" || return 1
    recorded_app_path="$(session_value "$session_dir" builtAppPath 2>/dev/null || true)"
    build_directory="$(debug_build_path print-derived-data-path)" || return 1
    output_dir="$(source_output_directory "$build_directory")" || return 1
    recorded_output_dirs="$(session_source_output_directories "$session_dir/session.plist")" || return 1
    local -aU output_dirs
    output_dirs=(${(0)recorded_output_dirs})
    [[ -z "$output_dir" ]] || output_dirs+=("$output_dir")

    local build_source_commit build_source_dirty build_source_tree
    build_source_commit="$(source_commit)"
    build_source_dirty="$(source_dirty "${output_dirs[@]}")"
    build_source_tree="$(source_tree_sha256 "${output_dirs[@]}")"

    print -r -- "env DEVELOPER_DIR='$E2E_DEVELOPER_DIR' make -C '$REPO_ROOT' build"
    print -r -- "env DEVELOPER_DIR='$E2E_DEVELOPER_DIR' make -C '$REPO_ROOT' sync-built-debug-plugins"
    print -r -- "Replace '$APP_PATH' from '$rebuilt_app_path'"
    if [[ "$mode" == --dry-run ]]; then
        return
    fi

    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" make -C "$REPO_ROOT" build
    local conflicting_processes
    conflicting_processes="$(conflicting_built_pids "$rebuilt_app_path" "$recorded_app_path")"
    [[ -z "$conflicting_processes" ]] || {
        print -u2 -r -- "error: a MacTools app is still running from Derived Data"
        return 1
    }
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" make -C "$REPO_ROOT" sync-built-debug-plugins
    [[ "$build_source_commit" == "$(source_commit)"
        && "$build_source_dirty" == "$(source_dirty "${output_dirs[@]}")"
        && "$build_source_tree" == "$(source_tree_sha256 "${output_dirs[@]}")" ]] || {
        print -u2 -r -- "error: source changed while E2E artifacts were being built"
        return 1
    }
    [[ -d "$rebuilt_app_path" ]] || {
        print -u2 -r -- "error: rebuilt app not found at $rebuilt_app_path"
        return 1
    }
    mkdir -p "$ARTIFACT_ROOT"
    local install_stage staged_app
    install_stage="$(mktemp -d "$ARTIFACT_ROOT/install-staging.XXXXXX")"
    staged_app="$install_stage/${APP_PATH:t}"
    /usr/bin/ditto --rsrc --extattr --acl "$rebuilt_app_path" "$staged_app"
    codesign --verify --deep --strict "$staged_app"

    local staged_bundle_id staged_signature staged_team expected_team
    staged_bundle_id="$(plist_value "$staged_app/Contents/Info.plist" CFBundleIdentifier)"
    staged_signature="$(codesign -dv --verbose=4 "$staged_app" 2>&1)"
    staged_team="$(print -r -- "$staged_signature" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    expected_team="$(expected_team_identifier)"
    [[ "$staged_bundle_id" == "$expected_bundle_id" ]] || {
        print -u2 -r -- "error: rebuilt bundle identifier $staged_bundle_id does not match $expected_bundle_id"
        return 1
    }
    [[ -n "$staged_team" && ( -z "$expected_team" || "$staged_team" == "$expected_team" ) ]] || {
        print -u2 -r -- "error: rebuilt Team ID $staged_team does not match $expected_team"
        return 1
    }

    stop_app
    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.before-rebuild.txt" 2>&1
    local stamp backup_app
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    backup_app="$session_dir/app-before-rebuild-$stamp.app"
    /bin/mv "$APP_PATH" "$backup_app"
    if /bin/mv "$staged_app" "$APP_PATH"; then
        /bin/rmdir "$install_stage"
    else
        /bin/mv "$backup_app" "$APP_PATH"
        return 1
    fi

    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.after-rebuild.txt" 2>&1
    cmp -s \
        "$session_dir/designated-requirement.before-rebuild.txt" \
        "$session_dir/designated-requirement.after-rebuild.txt" || {
        print -u2 -r -- "error: designated requirement changed across the stable rebuild"
        /bin/mv "$APP_PATH" "$session_dir/app-rejected-rebuild-$stamp.app"
        /bin/mv "$backup_app" "$APP_PATH"
        return 1
    }
    invalidate_session_recordings "$session_dir"
    write_session_provenance "$session_dir/session.plist" true "$rebuilt_app_path" "${output_dirs[@]}"
    plutil -replace preparedAt -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session_dir/session.plist"
    plutil -replace preparedAtEpoch -integer "$(date '+%s')" "$session_dir/session.plist"
    preflight "$session_dir/preflight.json" "$recorded_app_path" "$rebuilt_app_path"
    /usr/bin/open -n -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    print -r -- "Rebuilt stable app with an unchanged designated requirement."
    print -r -- "Recoverable previous app: $backup_app"
}

prepare() {
    require_app
    local stamp session_dir
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    session_dir="$ARTIFACT_ROOT/session-$stamp-$$"
    mkdir -p "$session_dir"

    preflight "$session_dir/preflight.json"
    stop_app

    local bundle_id extension_id
    bundle_id="$(app_bundle_identifier)"
    extension_id="$(extension_bundle_identifier)"
    local had_preferences=false
    local had_extension_preferences=false
    if save_domain "$bundle_id" "$session_dir/preferences.before.plist"; then
        had_preferences=true
    fi
    if [[ -n "$extension_id" ]] && save_domain "$extension_id" "$session_dir/extension-preferences.before.plist"; then
        had_extension_preferences=true
    fi
    write_session_metadata \
        "$session_dir/session.plist" "$bundle_id" "$extension_id" \
        "$had_preferences" "$had_extension_preferences"
    write_pending_checkpoints "$session_dir/ui-checkpoints.json"
    build_privacy_helpers "$session_dir"
    build_privacy_recorder "$session_dir"

    if ! fixture_tool seed --bundle-id "$bundle_id" --allow-real-domain >"$session_dir/fixture.seed.json"; then
        restore_domain "$bundle_id" "$had_preferences" "$session_dir/preferences.before.plist"
        if [[ -n "$extension_id" ]]; then
            restore_domain \
                "$extension_id" "$had_extension_preferences" \
                "$session_dir/extension-preferences.before.plist"
        fi
        return 1
    fi

    /usr/bin/open -n -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    local attempt
    for attempt in {1..100}; do
        [[ -n "$(matching_pids)" ]] && break
        sleep 0.1
    done
    local process_output process_count
    process_output="$(matching_pids)"
    process_count=0
    if [[ -n "$process_output" ]]; then
        process_count="$(print -r -- "$process_output" | wc -l | tr -d ' ')"
    fi
    if (( process_count != 1 )); then
        print -u2 -r -- "error: expected one stable-path process after launch, found $process_count"
        print -u2 -r -- "Restore with: $HARNESS_PATH restore '$session_dir'"
        return 1
    fi

    print -r -- "Prepared E2E session: $session_dir"
    print -r -- "Restore command: $HARNESS_PATH restore '$session_dir'"
    print -r -- "$session_dir"
}

reseed_session() {
    local session_dir="$1"
    validate_session_identity "$session_dir" || return 1
    local bundle_id
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"

    build_privacy_helpers "$session_dir"
    stop_app
    stop_privacy_helpers "$session_dir"
    ensure_privacy_helpers "$session_dir"
    local stamp evidence_path
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    evidence_path="$session_dir/fixture.reseed-$stamp.json"
    fixture_tool seed --bundle-id "$bundle_id" --allow-real-domain >"$evidence_path"
    /usr/bin/open -n -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"

    local attempt
    for attempt in {1..100}; do
        [[ -n "$(matching_pids)" ]] && break
        sleep 0.1
    done
    local process_count
    process_count="$(matching_pids | wc -l | tr -d ' ')"
    [[ "$process_count" == 1 ]] || {
        print -u2 -r -- "error: expected one stable-path process after reseed, found $process_count"
        return 1
    }
    print -r -- "Reseeded E2E fixture: $evidence_path"
}

upgrade_session() {
    local session_dir="$1"
    validate_session_identity "$session_dir" || return 1
    invalidate_session_recordings "$session_dir"
    plutil -replace preparedAtEpoch -integer "$(date '+%s')" "$session_dir/session.plist"
    write_pending_checkpoints "$session_dir/ui-checkpoints.json"
    reseed_session "$session_dir"
    print -r -- "Reset required checkpoints and recording evidence from $SCENARIO_MANIFEST"
}

invalidate_session_recordings() {
    local session_dir="$1"
    local -a artifacts
    artifacts=(
        "$session_dir"/screencast*.mov(N)
        "$session_dir"/screencast*.mp4(N)
        "$session_dir"/screencast*.sha256(N)
        "$session_dir"/screencast*.ready(N)
        "$session_dir"/screencast*.start(N)
        "$session_dir"/screencast*.stop(N)
    )
    (( ${#artifacts[@]} == 0 )) || rm -f -- "${artifacts[@]}"
}

session_value() {
    plist_value "$1/session.plist" "$2"
}

validate_session_identity() {
    local session_dir="$1"
    local allow_unbound="${2:-false}"
    local metadata="$session_dir/session.plist"
    [[ -f "$metadata" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    require_app || return 1

    local canonical_session canonical_root canonical_app recorded_app
    canonical_session="${session_dir:A}"
    canonical_root="${ARTIFACT_ROOT:A}"
    canonical_app="${APP_PATH:A}"
    recorded_app="$(session_value "$session_dir" appPath)"
    [[ "$canonical_session" == "$canonical_root"/* ]] || {
        print -u2 -r -- "error: session is outside the E2E artifact root"
        return 1
    }
    [[ "${recorded_app:A}" == "$canonical_app" ]] || {
        print -u2 -r -- "error: session app path does not match $APP_PATH"
        return 1
    }

    local recorded_bundle actual_bundle recorded_extension actual_extension
    recorded_bundle="$(session_value "$session_dir" bundleIdentifier)"
    actual_bundle="$(app_bundle_identifier)"
    recorded_extension="$(session_value "$session_dir" extensionBundleIdentifier)"
    actual_extension="$(extension_bundle_identifier)"
    [[ -n "$actual_bundle" && "$recorded_bundle" == "$actual_bundle" ]] || {
        print -u2 -r -- "error: session app bundle identifier does not match the installed app"
        return 1
    }
    [[ "$recorded_extension" == "$actual_extension" ]] || {
        print -u2 -r -- "error: session extension bundle identifier does not match the installed app"
        return 1
    }

    local recorded_version actual_version recorded_build actual_build
    recorded_version="$(session_value "$session_dir" appVersion)"
    actual_version="$(app_version)"
    recorded_build="$(session_value "$session_dir" appBuild)"
    actual_build="$(app_build)"
    [[ -n "$actual_version" && "$recorded_version" == "$actual_version" ]] || {
        print -u2 -r -- "error: session app version does not match the installed app"
        return 1
    }
    [[ -n "$actual_build" && "$recorded_build" == "$actual_build" ]] || {
        print -u2 -r -- "error: session app build does not match the installed app"
        return 1
    }

    local recorded_commit recorded_dirty recorded_source_tree source_build_bound
    local executable recorded_executable_hash actual_executable_hash
    recorded_commit="$(session_value "$session_dir" sourceCommit)"
    recorded_dirty="$(session_value "$session_dir" sourceDirty)"
    recorded_source_tree="$(session_value "$session_dir" sourceTreeSHA256)"
    source_build_bound="$(session_value "$session_dir" sourceBuildBound)"
    executable="$(app_executable)"
    recorded_executable_hash="$(session_value "$session_dir" appExecutableSHA256)"
    [[ -n "$recorded_commit" ]] || {
        print -u2 -r -- "error: session source commit is missing"
        return 1
    }
    [[ "$recorded_dirty" == true || "$recorded_dirty" == false ]] || {
        print -u2 -r -- "error: session source dirty state is invalid"
        return 1
    }
    if [[ "$allow_unbound" != true ]]; then
        local recorded_output_dirs actual_source_tree
        recorded_output_dirs="$(session_source_output_directories "$metadata")" || return 1
        local -a output_dirs
        output_dirs=(${(0)recorded_output_dirs})
        [[ "$recorded_commit" == "$(source_commit)"
            && "$recorded_dirty" == "$(source_dirty "${output_dirs[@]}")" ]] || {
            print -u2 -r -- "error: session source revision does not match the current checkout"
            return 1
        }
        [[ "$source_build_bound" == true ]] || {
            print -u2 -r -- "error: session artifacts are not bound to the recorded source; run '$HARNESS_PATH rebuild "$session_dir"'"
            return 1
        }
        actual_source_tree="$(source_tree_sha256 "${output_dirs[@]}")" || return 1
        [[ -n "$recorded_source_tree" && "$recorded_source_tree" == "$actual_source_tree" ]] || {
            print -u2 -r -- "error: session source tree hash does not match the current checkout"
            return 1
        }
    fi
    [[ -f "$executable" ]] || {
        print -u2 -r -- "error: installed app executable is missing"
        return 1
    }
    actual_executable_hash="$(sha256_file "$executable")"
    [[ -n "$recorded_executable_hash" && "$recorded_executable_hash" == "$actual_executable_hash" ]] || {
        print -u2 -r -- "error: session app executable hash does not match the installed app"
        return 1
    }
    codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || {
        print -u2 -r -- "error: installed app signature is invalid"
        return 1
    }

    local recorded_cdhash actual_cdhash recorded_plugin_hash actual_plugin_hash
    local recorded_catalog_hash actual_catalog_hash
    recorded_cdhash="$(session_value "$session_dir" appCodeDirectoryHash)"
    actual_cdhash="$(app_code_directory_hash)"
    [[ -n "$recorded_cdhash" && "$recorded_cdhash" == "$actual_cdhash" ]] || {
        print -u2 -r -- "error: session app CodeDirectory hash does not match the installed app"
        return 1
    }
    recorded_plugin_hash="$(session_value "$session_dir" pluginPackageTreeSHA256)"
    actual_plugin_hash="$(sha256_tree "$PLUGIN_INSTALL_DIR")"
    [[ -n "$recorded_plugin_hash" && "$recorded_plugin_hash" == "$actual_plugin_hash" ]] || {
        print -u2 -r -- "error: session plugin package tree hash does not match installed plugins"
        return 1
    }
    [[ -f "$PLUGIN_CATALOG_PATH" ]] || {
        print -u2 -r -- "error: local plugin catalog is missing at $PLUGIN_CATALOG_PATH"
        return 1
    }
    recorded_catalog_hash="$(session_value "$session_dir" pluginCatalogSHA256)"
    actual_catalog_hash="$(sha256_file "$PLUGIN_CATALOG_PATH")"
    [[ -n "$recorded_catalog_hash" && "$recorded_catalog_hash" == "$actual_catalog_hash" ]] || {
        print -u2 -r -- "error: session plugin catalog hash does not match the local catalog"
        return 1
    }

    local had_preferences had_extension_preferences
    had_preferences="$(session_value "$session_dir" hadPreferences)"
    had_extension_preferences="$(session_value "$session_dir" hadExtensionPreferences)"
    [[ "$had_preferences" == true || "$had_preferences" == false ]] || {
        print -u2 -r -- "error: session hadPreferences value is invalid"
        return 1
    }
    [[ "$had_extension_preferences" == true || "$had_extension_preferences" == false ]] || {
        print -u2 -r -- "error: session hadExtensionPreferences value is invalid"
        return 1
    }
    [[ "$had_preferences" != true || -f "$session_dir/preferences.before.plist" ]] || {
        print -u2 -r -- "error: session preferences backup is missing"
        return 1
    }
    [[ "$had_extension_preferences" != true || -f "$session_dir/extension-preferences.before.plist" ]] || {
        print -u2 -r -- "error: session extension preferences backup is missing"
        return 1
    }
}

audit_session() {
    local session_dir="$1"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    local bundle_id
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    fixture_tool audit --bundle-id "$bundle_id" | tee "$session_dir/fixture.audit.json"
}

checkpoint() {
    local session_dir="$1"
    local name="$2"
    local checkpoint_status="$3"
    local detail="${4:-}"
    [[ "$checkpoint_status" == pass || "$checkpoint_status" == fail || "$checkpoint_status" == pending ]] || {
        print -u2 -r -- "error: checkpoint status must be pass, fail, or pending"
        return 1
    }
    local recording_epoch=0
    if [[ -f "$session_dir/session.plist" ]]; then
        recording_epoch="$(session_value "$session_dir" preparedAtEpoch 2>/dev/null || true)"
        [[ "$recording_epoch" == <-> ]] || recording_epoch=0
    fi
    "$PYTHON3" - \
        "$session_dir/ui-checkpoints.json" \
        "$session_dir/report.json" \
        "$SCENARIO_MANIFEST" \
        "$SCRIPT_DIR" \
        "$FFPROBE" \
        "$recording_epoch" \
        "$name" "$checkpoint_status" "$detail" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, report_path, manifest_path, script_dir, ffprobe, recording_epoch, name, status, detail = sys.argv[1:]
sys.path.insert(0, script_dir)
from recording_validation import recording_artifact_status

with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
known_names = {
    checkpoint
    for pack in manifest["packs"]
    for checkpoint in pack["checkpoints"]
}
if name not in known_names:
    raise SystemExit(f"unknown checkpoint: {name}")
payload[name] = {
    "status": status,
    "detail": detail,
    "timestamp": datetime.now(timezone.utc).isoformat(),
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")

if os.path.isfile(report_path):
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    scenario_coverage = {}
    session = os.path.dirname(path)
    required_recordings_passed = True
    for pack in manifest["packs"]:
        pack_statuses = {
            checkpoint: payload.get(checkpoint, {"status": "not-required"})["status"]
            for checkpoint in pack["checkpoints"]
        }
        missing_recordings, invalid_recordings = recording_artifact_status(
            session, pack["id"], ffprobe, float(recording_epoch)
        ) if pack.get("recordingRequired", False) else ([], [])
        recording_passed = not missing_recordings and not invalid_recordings
        if pack.get("recordingRequired", False):
            required_recordings_passed = required_recordings_passed and recording_passed
        scenario_coverage[pack["id"]] = {
            "title": pack["title"],
            "phase": pack["phase"],
            "required": pack["required"],
            "recordingRequired": pack.get("recordingRequired", False),
            "missingRecordings": missing_recordings,
            "invalidRecordings": invalid_recordings,
            "recordingPassed": recording_passed,
            "checkpoints": pack_statuses,
            "passed": bool(pack_statuses)
                and all(value == "pass" for value in pack_statuses.values())
                and recording_passed,
        }
    required_names = [
        checkpoint
        for pack in manifest["packs"]
        if pack["required"]
        for checkpoint in pack["checkpoints"]
    ]
    required_statuses = [
        payload.get(checkpoint, {"status": "pending"})["status"]
        for checkpoint in required_names
    ]
    report["generatedAt"] = datetime.now(timezone.utc).isoformat()
    report["uiCheckpoints"] = payload
    report["scenarioCoverage"] = scenario_coverage
    report["passed"] = (
        report.get("preflight", {}).get("passed", False)
        and report.get("fixture", {}).get("valid", False)
        and set(required_names).issubset(payload)
        and bool(required_statuses)
        and all(value == "pass" for value in required_statuses)
        and required_recordings_passed
    )
    with open(report_path, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
PY
}

send_shortcut() {
    local session_dir="$1"
    local shortcut_name="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    key_sender_tool describe "$shortcut_name" >/dev/null
    if [[ "$mode" == --dry-run ]]; then
        key_sender_tool describe "$shortcut_name"
        return
    fi
    validate_session_identity "$session_dir" || return 1
    key_sender_tool check >/dev/null || {
        print -u2 -r -- "error: synthetic shortcut access is not granted; no key was sent"
        return 1
    }
    [[ "$(matching_pids | wc -l | tr -d ' ')" == 1 ]] || {
        print -u2 -r -- "error: expected exactly one stable MacTools process"
        return 1
    }
    /usr/bin/open -a Finder
    sleep 0.5
    key_sender_tool send "$shortcut_name"
}

send_pointer_click() {
    local session_dir="$1"
    local reference_width="$2"
    local reference_height="$3"
    local local_x="$4"
    local local_y="$5"
    local mode="${6:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    for value in "$reference_width" "$reference_height" "$local_x" "$local_y"; do
        [[ "$value" == <-> ]] || {
            print -u2 -r -- "error: pointer coordinates and reference dimensions must be non-negative integers"
            return 1
        }
    done
    (( reference_width > 0 && reference_height > 0 )) || {
        print -u2 -r -- "error: pointer reference dimensions must be positive"
        return 1
    }
    (( local_x <= reference_width && local_y <= reference_height )) || {
        print -u2 -r -- "error: pointer coordinate is outside the reference window"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Pointer click at ($local_x,$local_y) in ${reference_width}x${reference_height} focused MacTools window"
        return 0
    fi
    validate_session_identity "$session_dir" || return 1
    ensure_input_driver "$session_dir"
    local process_output process_id
    process_output="$(matching_pids)"
    [[ "$(print -r -- "$process_output" | wc -l | tr -d ' ')" == 1 ]] || {
        print -u2 -r -- "error: expected exactly one stable MacTools process before pointer input"
        return 1
    }
    process_id="${process_output%%$'\n'*}"
    input_driver_tool "$session_dir" click-relative \
        "$process_id" "$reference_width" "$reference_height" "$local_x" "$local_y"
}

send_input_select_all() {
    local session_dir="$1"
    local mode="${2:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Select all in the focused MacTools control"
        return 0
    fi
    validate_session_identity "$session_dir" || return 1
    ensure_input_driver "$session_dir"
    input_driver_tool "$session_dir" select-all
}

send_input_text() {
    local session_dir="$1"
    local input_text="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Type ${#input_text} characters into the focused MacTools control"
        return 0
    fi
    validate_session_identity "$session_dir" || return 1
    ensure_input_driver "$session_dir"
    input_driver_tool "$session_dir" type-text "$input_text"
}

send_input_key() {
    local session_dir="$1"
    local input_key="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    [[ "$input_key" == command-k || "$input_key" == return || "$input_key" == escape ]] || {
        print -u2 -r -- "error: input key must be command-k, return, or escape"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Press $input_key in MacTools"
        return 0
    fi
    validate_session_identity "$session_dir" || return 1
    ensure_input_driver "$session_dir"
    input_driver_tool "$session_dir" press-key "$input_key"
}

launch_privacy_helper_session() {
    local session_dir="$1"
    local variant="$2"
    local mode="${3:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    session_dir="${session_dir:A}"
    [[ "$variant" == primary || "$variant" == secondary ]] || {
        print -u2 -r -- "error: privacy helper variant must be primary or secondary"
        return 1
    }
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "$(privacy_helper_executable_path "$session_dir" "$variant")"
        return
    fi
    validate_session_identity "$session_dir" || return 1
    ensure_privacy_helpers "$session_dir"
    launch_privacy_helper_process "$session_dir" "$variant"
}

record_session() {
    local session_dir="$1"
    local duration="${2:-90}"
    local mode="${3:-}"
    local label="${4:-}"
    local start_route="${5:-settings/features/automation}"
    [[ "$duration" == <-> ]] && (( duration >= 1 && duration <= 600 )) || {
        print -u2 -r -- "error: recording duration must be between 1 and 600 seconds"
        return 1
    }
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }
    session_dir="${session_dir:A}"
    validate_recording_label "$label" || return 1
    local base_name="screencast"
    [[ -z "$label" ]] || base_name="screencast.$label"
    local mov="$session_dir/$base_name.mov"
    local mp4="$session_dir/$base_name.mp4"
    local temporary_mov="$session_dir/.$base_name.$$.mov"
    local temporary_mp4="$session_dir/.$base_name.$$.mp4"
    if [[ "$mode" == --dry-run ]]; then
        print -r -- "Hide unrelated apps reversibly, start the privacy backdrop, reactivate MacTools, then record"
        print -r -- "Story start route: mactools-dev://app/$start_route"
        print -r -- "ScreenCaptureKit allowlist: MacTools + session privacy helper"
        print -r -- "MacToolsE2ERecorder '$mov' '$duration' '<visible-MacTools-window>' '<ready-file>' '<first-action-file>' '<assertion-stop-file>' '<allowed-bundle-id>@<pid>...>'"
        return 0
    fi
    validate_session_identity "$session_dir" || return 1

    stop_privacy_helpers "$session_dir"
    build_privacy_helpers "$session_dir"
    ensure_privacy_recorder "$session_dir"
    ensure_input_driver "$session_dir"
    stop_app
    sleep 0.5
    local visibility_state
    visibility_state="$(recording_visibility_state_path "$session_dir")"
    rm -f -- "$visibility_state"
    /usr/bin/open -n -a "$APP_PATH"
    sleep 1
    key_sender_tool check >/dev/null || {
        print -u2 -r -- "error: synthetic shortcut access is required to establish the private Settings recording surface"
        return 1
    }
    key_sender_tool send open-settings >/dev/null
    sleep 1
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/$start_route"
    sleep 0.75
    launch_privacy_helper_process "$session_dir" backdrop \
        --recording-privacy \
        --visibility-state "$visibility_state" \
        --protected-bundle-id "$(app_bundle_identifier)"
    trap 'stop_privacy_helpers "$session_dir"' EXIT INT TERM
    sleep 0.75
    launch_privacy_helper_process "$session_dir" primary
    launch_privacy_helper_process "$session_dir" secondary
    sleep 0.5
    /usr/bin/open -a "$APP_PATH" "mactools-dev://app/$start_route"
    sleep 0.75

    local process_output process_id capture_rect
    process_output="$(matching_pids)"
    [[ "$(print -r -- "$process_output" | wc -l | tr -d ' ')" == 1 ]] || {
        stop_privacy_helpers "$session_dir"
        print -u2 -r -- "error: expected exactly one stable MacTools process before recording"
        return 1
    }
    process_id="${process_output%%$'\n'*}"
    capture_rect=""
    local capture_attempt
    for capture_attempt in {1..50}; do
        capture_rect="$(capture_rect_tool "$process_id" 2>/dev/null || true)"
        [[ "$capture_rect" == <->,<->,<->,<-> ]] && break
        sleep 0.2
    done
    [[ "$capture_rect" == <->,<->,<->,<-> ]] || {
        stop_privacy_helpers "$session_dir"
        print -u2 -r -- "error: no visible standard MacTools window is available for private recording"
        return 1
    }

    local app_bundle_id primary_helper_bundle_id secondary_helper_bundle_id backdrop_bundle_id
    local primary_helper_pid secondary_helper_pid backdrop_pid
    app_bundle_id="$(app_bundle_identifier)"
    primary_helper_bundle_id="$(plist_value "$(privacy_helper_app_path "$session_dir" primary)/Contents/Info.plist" CFBundleIdentifier)"
    secondary_helper_bundle_id="$(plist_value "$(privacy_helper_app_path "$session_dir" secondary)/Contents/Info.plist" CFBundleIdentifier)"
    backdrop_bundle_id="$(plist_value "$(privacy_helper_app_path "$session_dir" backdrop)/Contents/Info.plist" CFBundleIdentifier)"
    primary_helper_pid="$(single_executable_pid "$(privacy_helper_executable_path "$session_dir" primary)" "primary privacy helper")" || return 1
    secondary_helper_pid="$(single_executable_pid "$(privacy_helper_executable_path "$session_dir" secondary)" "secondary privacy helper")" || return 1
    backdrop_pid="$(single_executable_pid "$(privacy_helper_executable_path "$session_dir" backdrop)" "privacy backdrop")" || return 1
    local ready_marker start_marker stop_marker
    ready_marker="$(recording_marker_path "$session_dir" "$label" ready)"
    start_marker="$(recording_marker_path "$session_dir" "$label" start)"
    stop_marker="$(recording_marker_path "$session_dir" "$label" stop)"
    print -r -- "ScreenCaptureKit application allowlist: $app_bundle_id@$process_id, $primary_helper_bundle_id@$primary_helper_pid, $secondary_helper_bundle_id@$secondary_helper_pid, $backdrop_bundle_id@$backdrop_pid"
    print -r -- "Recording readiness marker: $ready_marker"
    print -r -- "First action marker: $start_marker"
    print -r -- "Assertion stop marker: $stop_marker"
    rm -f -- "$temporary_mov" "$temporary_mp4" "$ready_marker" "$start_marker" "$stop_marker"
    if ! privacy_recorder_tool "$session_dir" \
        "$temporary_mov" "$duration" "$capture_rect" "$ready_marker" "$start_marker" "$stop_marker" \
        "$app_bundle_id@$process_id" \
        "$primary_helper_bundle_id@$primary_helper_pid" \
        "$secondary_helper_bundle_id@$secondary_helper_pid" \
        "$backdrop_bundle_id@$backdrop_pid"; then
        stop_privacy_helpers "$session_dir"
        rm -f -- "$temporary_mov" "$temporary_mp4" "$ready_marker" "$start_marker" "$stop_marker"
        return 1
    fi
    rm -f -- "$ready_marker" "$start_marker" "$stop_marker"
    stop_privacy_helpers "$session_dir"
    trap - EXIT INT TERM
    if ! "$FFMPEG" -hide_banner -loglevel error -y -i "$temporary_mov" \
        -an -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
        -movflags +faststart "$temporary_mp4"; then
        rm -f -- "$temporary_mov" "$temporary_mp4"
        return 1
    fi
    mv -f -- "$temporary_mov" "$mov"
    mv -f -- "$temporary_mp4" "$mp4"
    shasum -a 256 "$mov" "$mp4" >"$session_dir/$base_name.sha256"
}

record_pack_session() {
    local session_dir="$1"
    local pack_id="$2"
    local duration="${3:-90}"
    local mode="${4:-}"
    print_scenarios "$pack_id" >/dev/null
    local start_route
    start_route="$(recording_start_route "$pack_id")"
    record_session "$session_dir" "$duration" "$mode" "$pack_id" "$start_route"
    if [[ "$mode" != --dry-run ]]; then
        checkpoint "$session_dir" screencast-captured pass \
            "Recorded scenario pack $pack_id"
    fi
}

verify_code_session() {
    local session_dir="$1"
    local mode="${2:-}"
    [[ -f "$session_dir/session.plist" ]] || {
        print -u2 -r -- "error: invalid E2E session directory $session_dir"
        return 1
    }

    local -a common_args
    common_args=(
        -project "$REPO_ROOT/MacTools.xcodeproj"
        -scheme MacTools
        -configuration Debug
        -derivedDataPath "$REPO_ROOT/build/DerivedData"
        test
        -quiet
    )
    print -r -- "Run PluginCatalogManagerTests with xcodebuild"
    print -r -- "Run action-registry core coverage and native action-provider suites with xcodebuild"
    print -r -- "Run the six injected Trackpad Gestures test classes with xcodebuild"
    if [[ "$mode" == --dry-run ]]; then
        return 0
    fi
    require_app

    local result=0
    stop_app
    trap 'restore_stable_app_after_code_verification' EXIT
    stop_built_app
    restore_stable_launch_services_registration
    if env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcodebuild "${common_args[@]}" \
        -only-testing:MacToolsTests/PluginCatalogManagerTests \
        2>&1 | tee "$session_dir/code-verification.migration.log"; then
        checkpoint "$session_dir" plugin-migration-isolated-tests pass \
            "PluginCatalogManagerTests passed"
    else
        checkpoint "$session_dir" plugin-migration-isolated-tests fail \
            "See code-verification.migration.log"
        result=1
    fi
    stop_built_app
    restore_stable_launch_services_registration

    if env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcodebuild "${common_args[@]}" \
        -only-testing:MacToolsTests/ActionRegistryTests \
        -only-testing:MacToolsTests/ActionExecutorTests \
        -only-testing:MacToolsTests/ActionRunLinkServiceTests \
        -only-testing:MacToolsTests/AutomationControllerTests \
        -only-testing:MacToolsTests/WorkflowRunnerTests \
        -only-testing:MacToolsTests/PluginHostActionRegistryTests \
        -only-testing:MacToolsTests/ActionGridPluginTests \
        -only-testing:MacToolsTests/ActivityBarPluginTests \
        -only-testing:MacToolsTests/AIAssistantPluginTests \
        -only-testing:MacToolsTests/AppearancePluginTests \
        -only-testing:MacToolsTests/AppleShortcutsPluginTests \
        -only-testing:MacToolsTests/AppHotkeyPluginTests \
        -only-testing:MacToolsTests/AppVolumePluginTests \
        -only-testing:MacToolsTests/AutoHideDockPluginTests \
        -only-testing:MacToolsTests/AutoHideMenuBarPluginTests \
        -only-testing:MacToolsTests/AutoInputPluginPanelTests \
        -only-testing:MacToolsTests/BatteryChargeLimitPluginTests \
        -only-testing:MacToolsTests/ClipboardClearPluginTests \
        -only-testing:MacToolsTests/ClipboardHistoryPluginTests \
        -only-testing:MacToolsTests/CloudflareR2PluginTests \
        -only-testing:MacToolsTests/DiskCleanPluginTests \
        -only-testing:MacToolsTests/DisplayBrightnessPluginTests \
        -only-testing:MacToolsTests/DisplayResolutionPluginTests \
        -only-testing:MacToolsTests/DisplaySleepPluginTests \
        -only-testing:MacToolsTests/DisplayTrueColorPluginTests \
        -only-testing:MacToolsTests/DisplayVolumePluginTests \
        -only-testing:MacToolsTests/DockLockPluginTests \
        -only-testing:MacToolsTests/EjectDiskPluginTests \
        -only-testing:MacToolsTests/EmptyTrashPluginTests \
        -only-testing:MacToolsTests/FanControlPluginTests \
        -only-testing:MacToolsTests/FixDamagedAppPluginTests \
        -only-testing:MacToolsTests/HideNotchPluginTests \
        -only-testing:MacToolsTests/HomebrewPluginTests \
        -only-testing:MacToolsTests/IPOverviewPluginTests \
        -only-testing:MacToolsTests/KeepAwakePreferenceTests \
        -only-testing:MacToolsTests/LaunchControlCanonicalActionTests \
        -only-testing:MacToolsTests/LaunchpadPluginActionTests \
        -only-testing:MacToolsTests/LockScreenPluginTests \
        -only-testing:MacToolsTests/MenuBarHiddenPluginTests \
        -only-testing:MacToolsTests/MicrophoneMutePluginTests \
        -only-testing:MacToolsTests/MiddleClickPluginTests \
        -only-testing:MacToolsTests/NightShiftPluginTests \
        -only-testing:MacToolsTests/PhysicalCleanModePluginTests \
        -only-testing:MacToolsTests/SiriPluginTests \
        -only-testing:MacToolsTests/QuitAppsPluginTests \
        -only-testing:MacToolsTests/SavedScriptsPluginTests \
        -only-testing:MacToolsTests/ScreenshotPluginTests \
        -only-testing:MacToolsTests/SidecarPluginTests \
        -only-testing:MacToolsTests/StageManagerPluginTests \
        -only-testing:MacToolsTests/SystemMutePluginTests \
        -only-testing:MacToolsTests/SystemPowerControllerTests \
        -only-testing:MacToolsTests/SystemPowerPluginTests \
        -only-testing:MacToolsTests/SystemSoftRestartPluginTests \
        -only-testing:MacToolsTests/TranslatorPluginTests \
        -only-testing:MacToolsTests/WindowLayoutsPluginTests \
        -only-testing:MacToolsTests/WindowSwitcherPluginTests \
        -only-testing:MacToolsTests/XcodeCleanPluginTests \
        2>&1 | tee "$session_dir/code-verification.action-registry.log"; then
        checkpoint "$session_dir" action-registry-health pass \
            "Core registry coverage and native action-provider suites passed"
    else
        checkpoint "$session_dir" action-registry-health fail \
            "See code-verification.action-registry.log"
        result=1
    fi
    stop_built_app
    restore_stable_launch_services_registration

    if env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcodebuild "${common_args[@]}" \
        -only-testing:MacToolsTests/TrackpadTypingSuppressionGateTests \
        -only-testing:MacToolsTests/TrackpadMiddleClickArbiterTests \
        -only-testing:MacToolsTests/TrackpadMiddleClickCoordinatorTests \
        -only-testing:MacToolsTests/TrackpadGestureStoreTests \
        -only-testing:MacToolsTests/TrackpadGesturesPluginTests \
        -only-testing:MacToolsTests/TrackpadGestureRecognizerTests \
        2>&1 | tee "$session_dir/code-verification.trackpad.log"; then
        checkpoint "$session_dir" trackpad-automated-tests pass \
            "Injected Trackpad Gestures suites passed"
    else
        checkpoint "$session_dir" trackpad-automated-tests fail \
            "See code-verification.trackpad.log"
        result=1
    fi
    stop_built_app
    restore_stable_launch_services_registration
    /usr/bin/open -n -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    trap - EXIT
    return "$result"
}

collect_session() {
    local session_dir="$1"
    validate_session_identity "$session_dir" || return 1
    preflight "$session_dir/preflight.json" "$(session_value "$session_dir" builtAppPath 2>/dev/null || true)" >/dev/null || true
    audit_session "$session_dir" >/dev/null
    codesign -dv --verbose=4 "$APP_PATH" >"$session_dir/signature.txt" 2>&1
    codesign -d -r- "$APP_PATH" >"$session_dir/designated-requirement.txt" 2>&1
    matching_pids >"$session_dir/processes.txt" || true
    local bundle_id start_epoch end_epoch
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    start_epoch="$(session_value "$session_dir" preparedAtEpoch 2>/dev/null || true)"
    if [[ "$start_epoch" != <-> ]]; then
        local prepared_at
        prepared_at="$(plutil -extract preparedAt raw -o - "$session_dir/session.plist")"
        start_epoch="$("$PYTHON3" - "$prepared_at" <<'PY'
import datetime
import sys

print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))
PY
)"
    fi
    [[ "$start_epoch" == <-> ]] || {
        print -u2 -r -- "error: invalid preparedAtEpoch in $session_dir/session.plist"
        return 1
    }
    end_epoch="$(date '+%s')"
    /usr/bin/log show --start "@$start_epoch" --end "@$end_epoch" --style compact \
        --predicate "subsystem == '$bundle_id' AND ((category == 'PluginHost' AND eventMessage BEGINSWITH 'Action registry ') OR category == 'TrackpadGesturesPlugin' OR category == 'MultitouchDeviceSession' OR category == 'MultitouchDeviceDriver')" \
        2>/dev/null | tail -2000 >"$session_dir/app.log" || true

    "$PYTHON3" - "$session_dir" "$SCENARIO_MANIFEST" "$SCRIPT_DIR" "$FFPROBE" "$start_epoch" <<'PY'
import hashlib
import json
import glob
import os
import plistlib
import sys
from datetime import datetime, timezone

session = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    scenario_manifest = json.load(handle)
sys.path.insert(0, sys.argv[3])
from recording_validation import recording_artifact_status
ffprobe = sys.argv[4]
recording_epoch = float(sys.argv[5])

def load(name):
    with open(os.path.join(session, name), encoding="utf-8") as handle:
        return json.load(handle)

fixture = load("fixture.audit.json")
preflight = load("preflight.json")
checkpoints = load("ui-checkpoints.json")
with open(os.path.join(session, "session.plist"), "rb") as handle:
    metadata = plistlib.load(handle)
provenance = {
    "sourceCommit": metadata["sourceCommit"],
    "sourceDirty": metadata["sourceDirty"],
    "sourceTreeSHA256": metadata["sourceTreeSHA256"],
    "sourceOutputDirectories": metadata.get(
        "sourceOutputDirectories", [metadata["sourceOutputDirectory"]] if metadata.get("sourceOutputDirectory") else [],
    ),
    "sourceBuildBound": metadata["sourceBuildBound"],
    "appVersion": metadata["appVersion"],
    "appBuild": metadata["appBuild"],
    "appExecutableSHA256": metadata["appExecutableSHA256"],
    "appCodeDirectoryHash": metadata["appCodeDirectoryHash"],
    "pluginPackageTreeSHA256": metadata["pluginPackageTreeSHA256"],
    "pluginCatalogSHA256": metadata["pluginCatalogSHA256"],
}
recordings = {}
for path in sorted(glob.glob(os.path.join(session, "screencast*.mov")) + glob.glob(os.path.join(session, "screencast*.mp4"))):
    name = os.path.basename(path)
    if os.path.isfile(path):
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        recordings[name] = {"bytes": os.path.getsize(path), "sha256": digest.hexdigest()}

def hashed_artifacts(pattern):
    artifacts = {}
    for path in sorted(glob.glob(os.path.join(session, pattern))):
        if not os.path.isfile(path):
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        artifacts[os.path.basename(path)] = {
            "bytes": os.path.getsize(path),
            "sha256": digest.hexdigest(),
        }
    return artifacts

screenshots = hashed_artifacts("screenshot*.png")
code_verification_logs = hashed_artifacts("code-verification.*.log")

required_packs = [pack for pack in scenario_manifest["packs"] if pack["required"]]
required_checkpoint_names = [
    name for pack in required_packs for name in pack["checkpoints"]
]
required_statuses = [
    checkpoints.get(name, {"status": "pending"})["status"]
    for name in required_checkpoint_names
]
scenario_coverage = {}
required_recordings_passed = True
for pack in scenario_manifest["packs"]:
    pack_statuses = {
        name: checkpoints.get(name, {"status": "not-required"})["status"]
        for name in pack["checkpoints"]
    }
    missing_recordings, invalid_recordings = recording_artifact_status(
        session, pack["id"], ffprobe, recording_epoch
    ) if pack.get("recordingRequired", False) else ([], [])
    recording_passed = not missing_recordings and not invalid_recordings
    if pack.get("recordingRequired", False):
        required_recordings_passed = required_recordings_passed and recording_passed
    scenario_coverage[pack["id"]] = {
        "title": pack["title"],
        "phase": pack["phase"],
        "required": pack["required"],
        "recordingRequired": pack.get("recordingRequired", False),
        "missingRecordings": missing_recordings,
        "invalidRecordings": invalid_recordings,
        "recordingPassed": recording_passed,
        "checkpoints": pack_statuses,
        "passed": bool(pack_statuses)
            and all(status == "pass" for status in pack_statuses.values())
            and recording_passed,
    }
payload = {
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "preflight": preflight,
    "fixture": fixture,
    "uiCheckpoints": checkpoints,
    "scenarioManifestVersion": scenario_manifest["formatVersion"],
    "scenarioCoverage": scenario_coverage,
    "provenance": provenance,
    "recordings": recordings,
    "screenshots": screenshots,
    "codeVerificationLogs": code_verification_logs,
    "passed": preflight.get("passed", False)
        and fixture.get("valid", False)
        and set(required_checkpoint_names).issubset(checkpoints)
        and bool(required_statuses)
        and all(status == "pass" for status in required_statuses)
        and required_recordings_passed,
}
with open(os.path.join(session, "report.json"), "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    print -r -- "Collected report: $session_dir/report.json"
}

restore_session() {
    local session_dir="$1"
    validate_session_identity "$session_dir" || return 1
    build_privacy_helpers "$session_dir"
    stop_app
    stop_privacy_helpers "$session_dir"

    local bundle_id extension_id had_preferences had_extension_preferences
    bundle_id="$(session_value "$session_dir" bundleIdentifier)"
    extension_id="$(session_value "$session_dir" extensionBundleIdentifier)"
    had_preferences="$(session_value "$session_dir" hadPreferences)"
    had_extension_preferences="$(session_value "$session_dir" hadExtensionPreferences)"
    restore_domain "$bundle_id" "$had_preferences" "$session_dir/preferences.before.plist"
    if [[ -n "$extension_id" ]]; then
        restore_domain \
            "$extension_id" "$had_extension_preferences" \
            "$session_dir/extension-preferences.before.plist"
    fi
    touch "$session_dir/restored.ok"
    /usr/bin/open -n -a "$APP_PATH" "mactools-dev://app/settings/plugins/marketplace"
    print -r -- "Restored preferences from $session_dir"
}

session_identity_self_test() {
    (
    local test_root
    test_root="$(mktemp -d "${TMPDIR:-/tmp}/mactools-e2e-session-test.XXXXXX")"
    local APP_PATH="$test_root/MacTools Test.app"
    local ARTIFACT_ROOT="$test_root/artifacts"
    local session_dir="$ARTIFACT_ROOT/session-valid"
    local app_plist="$APP_PATH/Contents/Info.plist"
    local extension_plist="$APP_PATH/Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
    trap '/bin/rm -rf -- "$test_root"' EXIT
    mkdir -p "$session_dir" "${app_plist:h}" "${extension_plist:h}"
    mkdir -p "$APP_PATH/Contents/MacOS"
    plutil -create xml1 "$app_plist"
    plutil -insert CFBundleIdentifier -string "com.example.mactools-test" "$app_plist"
    plutil -insert CFBundleExecutable -string "MacToolsTest" "$app_plist"
    plutil -insert CFBundleShortVersionString -string "1.2.0" "$app_plist"
    plutil -insert CFBundleVersion -string "1" "$app_plist"
    print -r -- "test executable" >"$APP_PATH/Contents/MacOS/MacToolsTest"
    chmod +x "$APP_PATH/Contents/MacOS/MacToolsTest"
    plutil -create xml1 "$extension_plist"
    plutil -insert CFBundleIdentifier -string "com.example.mactools-test.finder" "$extension_plist"
    write_session_metadata \
        "$session_dir/session.plist" \
        "com.example.mactools-test" \
        "com.example.mactools-test.finder" \
        false false
    validate_session_identity "$session_dir"

    plutil -replace bundleIdentifier -string "com.example.forged" "$session_dir/session.plist"
    if validate_session_identity "$session_dir" 2>/dev/null; then
        print -u2 -r -- "error: forged session bundle identifier was accepted"
        return 1
    fi
    print -r -- '{"sentinel":true}' >"$session_dir/ui-checkpoints.json"
    /usr/bin/touch "$session_dir/screencast.invalid.mov"
    /bin/cp "$session_dir/session.plist" "$session_dir/session.before-invalid-upgrade.plist"
    /bin/cp "$session_dir/ui-checkpoints.json" "$session_dir/ui-checkpoints.before-invalid-upgrade.json"
    if upgrade_session "$session_dir" 2>/dev/null; then
        print -u2 -r -- "error: upgrade accepted forged session identity"
        return 1
    fi
    [[ -f "$session_dir/screencast.invalid.mov" ]] \
        && cmp -s "$session_dir/session.plist" "$session_dir/session.before-invalid-upgrade.plist" \
        && cmp -s "$session_dir/ui-checkpoints.json" "$session_dir/ui-checkpoints.before-invalid-upgrade.json" || {
        print -u2 -r -- "error: invalid upgrade mutated session artifacts before validation"
        return 1
    }
    if rebuild_session "$session_dir" --dry-run >/dev/null 2>&1; then
        print -u2 -r -- "error: rebuild accepted forged session identity"
        return 1
    fi
    plutil -replace bundleIdentifier -string "com.example.mactools-test" "$session_dir/session.plist"
    plutil -replace appPath -string "$test_root/Other.app" "$session_dir/session.plist"
    if validate_session_identity "$session_dir" 2>/dev/null; then
        print -u2 -r -- "error: forged session app path was accepted"
        return 1
    fi
    plutil -replace appPath -string "$APP_PATH" "$session_dir/session.plist"
    plutil -replace hadPreferences -bool true "$session_dir/session.plist"
    if validate_session_identity "$session_dir" 2>/dev/null; then
        print -u2 -r -- "error: session with a missing preferences backup was accepted"
        return 1
    fi
    plutil -replace hadPreferences -bool false "$session_dir/session.plist"

    local outside_session="$test_root/outside-session"
    mkdir -p "$outside_session"
    /bin/cp "$session_dir/session.plist" "$outside_session/session.plist"
    if validate_session_identity "$outside_session" 2>/dev/null; then
        print -u2 -r -- "error: session outside the artifact root was accepted"
        return 1
    fi
    )
}

self_test() {
    local domain="com.jennymedia.mactools.e2e-test.$$.${RANDOM}"
    trap 'fixture_tool clear-test-domain --bundle-id "$domain" >/dev/null 2>&1 || true' EXIT
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -typecheck -framework AppKit "$APP_CONTROLLER_TOOL"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -typecheck -framework ApplicationServices -framework CoreGraphics \
        "$KEY_SENDER_TOOL"
    env DEVELOPER_DIR="$E2E_DEVELOPER_DIR" xcrun swiftc \
        -typecheck -parse-as-library -framework AppKit "$PRIVACY_HELPER_SOURCE"
    session_identity_self_test
    fixture_tool seed --bundle-id "$domain" >/dev/null
    fixture_tool audit --bundle-id "$domain"
    fixture_tool clear-test-domain --bundle-id "$domain"
    trap - EXIT
}

command="${1:-}"
case "$command" in
    preflight)
        preflight "${2:-}"
        ;;
    prepare)
        prepare
        ;;
    upgrade)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        upgrade_session "$2"
        ;;
    reseed)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        reseed_session "$2"
        ;;
    resume)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        resume_session "$2"
        ;;
    rebuild)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        rebuild_session "$2" "${3:-}"
        ;;
    audit)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        audit_session "$2"
        ;;
    checkpoint)
        [[ $# -ge 4 ]] || { usage; exit 1; }
        checkpoint "$2" "$3" "$4" "${5:-}"
        ;;
    shortcut)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        send_shortcut "$2" "$3" "${4:-}"
        ;;
    pointer-click)
        [[ $# -ge 6 ]] || { usage; exit 1; }
        send_pointer_click "$2" "$3" "$4" "$5" "$6" "${7:-}"
        ;;
    input-select-all)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        send_input_select_all "$2" "${3:-}"
        ;;
    input-text)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        send_input_text "$2" "$3" "${4:-}"
        ;;
    input-key)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        send_input_key "$2" "$3" "${4:-}"
        ;;
    privacy-helper)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        launch_privacy_helper_session "$2" "$3" "${4:-}"
        ;;
    record)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        record_session "$2" "${3:-90}" "${4:-}"
        ;;
    record-pack)
        [[ $# -ge 3 ]] || { usage; exit 1; }
        record_pack_session "$2" "$3" "${4:-90}" "${5:-}"
        ;;
    wait-recording-ready)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        wait_recording_ready "$2" "${3:-}" "${4:-15}"
        ;;
    start-recording)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        start_recording "$2" "${3:-}"
        ;;
    stop-recording)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        stop_recording "$2" "${3:-}"
        ;;
    verify-code)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        verify_code_session "$2" "${3:-}"
        ;;
    scenarios)
        print_scenarios "${2:-}"
        ;;
    collect)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        collect_session "$2"
        ;;
    restore)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        restore_session "$2"
        ;;
    self-test)
        self_test
        ;;
    *)
        usage
        exit 1
        ;;
esac
