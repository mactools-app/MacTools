#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
mode="${1:-test}"
case "$mode" in
    test|build|build-routing-pair|preflight|native-menu|desktop) ;;
    *) printf 'Usage: %s [test|build|build-routing-pair|preflight|native-menu|desktop]\n' "$0" >&2; exit 2 ;;
esac

output_dir="$(mktemp -d "${TMPDIR:-/tmp}/mactools-quit-protection.XXXXXX")"
if [[ "$mode" != build && "$mode" != build-routing-pair ]]; then
    trap 'rm -rf -- "$output_dir"' EXIT
fi

fixture_dir="$repo_root/scripts/fixtures/quit-protection"
sources=("$repo_root/Plugins/QuitProtection/Sources/QuitProtectionGesture.swift"
         "$repo_root/Plugins/QuitProtection/Sources/QuitProtectionRule.swift"
         "$repo_root/Plugins/QuitProtection/Sources/QuitProtectionInputRouting.swift"
         "$repo_root/Plugins/QuitProtection/Sources/QuitProtectionKeyboardLayout.swift")
swift_flags=(-swift-version 6 -module-cache-path "$output_dir/module-cache")

if [[ "$mode" == test ]]; then
    xcrun swiftc "${swift_flags[@]}" "${sources[@]}" \
        "$repo_root/Plugins/QuitProtection/Sources/QuitProtectionChromeQuit.swift" \
        "$fixture_dir/QuitProtectionGestureTests.swift" -o "$output_dir/tests"
    "$output_dir/tests"
    exit
fi

app="$output_dir/Quit Protection Fixture.app"
executable="$app/Contents/MacOS/QuitProtectionFixture"
mkdir -p -- "$(dirname -- "$executable")"
cp -- "$fixture_dir/Info.plist" "$app/Contents/Info.plist"
xcrun swiftc "${swift_flags[@]}" "${sources[@]}" "$fixture_dir/Fixture.swift" -o "$executable"

case "$mode" in
    preflight) "$executable" --preflight ;;
    native-menu) "$executable" --verify-native-menu ;;
    desktop) "$executable" --verify-desktop ;;
    build) printf '%s\n' "$executable" ;;
    build-routing-pair)
        for role in A B; do
            name="Quit Protection Fixture $role"
            fixture="$output_dir/$name.app"
            cp -R -- "$app" "$fixture"
            plutil -replace CFBundleIdentifier -string "com.mactools.quit-protection.fixture-$role" "$fixture/Contents/Info.plist"
            plutil -replace CFBundleName -string "$name" "$fixture/Contents/Info.plist"
        done
        printf '%s\n' "$output_dir"
        ;;
esac
