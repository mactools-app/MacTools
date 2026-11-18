#!/bin/bash
# On-demand desktop evidence. Uses only new temporary files, synthetic suites and an owned window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
PRODUCTS="$(make -s --no-print-directory print-test-products-dir)"
EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/MacToolsBackupEvidence.XXXXXX")"
CAPTURE_PID=""
cleanup() {
  if [[ -n "$CAPTURE_PID" ]]; then kill "$CAPTURE_PID" 2>/dev/null || true; fi
  if [[ -x "$EVIDENCE_DIR/desktop-acceptance" ]]; then
    "$EVIDENCE_DIR/desktop-acceptance" cleanup "$EVIDENCE_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
printf 'Evidence directory: %s\n' "$EVIDENCE_DIR"
uuidgen > "$EVIDENCE_DIR/suite-name.txt"
mkdir "$EVIDENCE_DIR/native"
xcrun swiftc scripts/testing/preferences-backup/capture-window.swift -o "$EVIDENCE_DIR/capture-window"
"$EVIDENCE_DIR/capture-window" "$EVIDENCE_DIR/native" > "$EVIDENCE_DIR/capture.log" 2>&1 &
CAPTURE_PID=$!
TEST_RUNNER_MACTOOLS_BACKUP_EVIDENCE_DIR="$EVIDENCE_DIR/native" \
MACTOOLS_BACKUP_EVIDENCE_DIR="$EVIDENCE_DIR/native" \
make test TEST_FILTER=PreferencesBackupDesktopEvidenceTests > "$EVIDENCE_DIR/native.log" 2>&1
wait "$CAPTURE_PID"
CAPTURE_PID=""
xcrun swiftc scripts/testing/preferences-backup/target-window.swift -o "$EVIDENCE_DIR/target-window"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -I "$PRODUCTS" -F "$PRODUCTS" -L "$PRODUCTS" -lWindowLayoutsPluginCore \
  -framework MacToolsPluginKit -framework AppKit -framework ApplicationServices \
  -Xlinker -rpath -Xlinker "$PRODUCTS" \
  scripts/testing/preferences-backup/desktop-acceptance.swift -o "$EVIDENCE_DIR/desktop-acceptance"
"$EVIDENCE_DIR/desktop-acceptance" granted "$EVIDENCE_DIR"
"$EVIDENCE_DIR/desktop-acceptance" relaunch "$EVIDENCE_DIR"
python3 - "$EVIDENCE_DIR" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys
root = Path(sys.argv[1])
contents = root / "Backup Denied QA.app" / "Contents"
(contents / "MacOS").mkdir(parents=True)
shutil.copy2(root / "desktop-acceptance", contents / "MacOS" / "backup-acceptance")
token = (root / "suite-name.txt").read_text().strip().lower()
(contents / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "org.mactools.backup-evidence.denied." + token,
    "CFBundleExecutable": "backup-acceptance", "CFBundleName": "MacTools Backup Denied QA",
    "CFBundlePackageType": "APPL", "LSUIElement": True,
}))
PY
open -n -W "$EVIDENCE_DIR/Backup Denied QA.app" --args denied "$EVIDENCE_DIR"
python3 - "$EVIDENCE_DIR" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for mode in ("granted", "relaunch", "denied"):
    report = json.loads((root / ("desktop-" + mode + ".json")).read_text())
    if report["result"] != "passed":
        raise SystemExit(f"Desktop acceptance failed: {mode}: {report}")
print(f"Desktop acceptance passed. Inspect native PNGs and AX reports in {root}.")
PY
