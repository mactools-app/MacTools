#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
APP_VERSION_CONFIG="$ROOT_DIR/Configs/AppVersion.xcconfig"
PROJECT_FILE="$ROOT_DIR/MacTools.xcodeproj"
XCODEBUILD="${XCODEBUILD:-$SCRIPT_DIR/xcodebuild-filtered.sh}"
APP_NAME="MacTools"
APP_ENTITLEMENTS="$ROOT_DIR/Configs/MacTools.entitlements"
FINDER_SYNC_ENTITLEMENTS="$ROOT_DIR/Sources/Extensions/RightClickFinderSync/RightClickFinderSync.entitlements"
SCHEME="MacTools"
CONFIG_FILE="${RELEASE_CONFIG_FILE:-$SCRIPT_DIR/release.local.env}"
DEFAULT_GITHUB_REPOSITORY="ggbond268/MacTools"

VERSION=""
BUILD_NUMBER=""
TAG=""
NOTES_FILE=""
SPARKLE_NOTES_FILE=""
PUBLISH=0
PUBLISH_EXISTING=0
SKIP_BUILD=0
SKIP_SIGN=0
SKIP_NOTARIZE=0
FORCE=0

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

function usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-local.sh [options]

Options:
  --version <version>        Release marketing version. Defaults to Configs/AppVersion.xcconfig.
  --build-number <number>    Release build number. Defaults to Configs/AppVersion.xcconfig.
  --tag <tag>                Git tag / release tag. Defaults to v<version>.
  --notes-file <path>        Release notes file for GitHub Release upload.
  --publish                  Push the tag and sync the DMG to GitHub Releases.
  --publish-existing         Upload the existing DMG artifact without rebuilding.
  --skip-build               Reuse the existing Release app in build/DerivedData.
  --skip-sign                Skip Developer ID signing. Implies --skip-notarize.
  --skip-notarize            Skip notarization and stapling.
  --force                    Recreate the local tag if it already points elsewhere.
  -h, --help                 Show this help message.

Environment:
  Copy scripts/release.local.env.sample to scripts/release.local.env
  and set:
    DEVELOPER_ID_APPLICATION
    APPLE_NOTARY_PROFILE
    GITHUB_REPOSITORY
    DMG_SIGNING_IDENTIFIER (optional)
    SPARKLE_KEYCHAIN_ACCOUNT (optional)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --publish-existing)
      PUBLISH_EXISTING=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-sign)
      SKIP_SIGN=1
      SKIP_NOTARIZE=1
      shift
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

function info() {
  printf '[release] %s\n' "$1"
}

function fail() {
  printf '[release] error: %s\n' "$1" >&2
  exit 1
}

function require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

function available_code_signing_identities() {
  security find-identity -v -p codesigning 2>/dev/null || true
}

function require_release_signing_identity() {
  local identities matched_identity

  identities="$(available_code_signing_identities)"
  [[ -n "$identities" ]] || fail "当前钥匙串里没有可用的代码签名身份。"

  matched_identity="$(printf '%s\n' "$identities" | grep -F "\"$DEVELOPER_ID_APPLICATION\"" || true)"

  if [[ -z "$matched_identity" ]]; then
    fail "未找到签名身份 \"$DEVELOPER_ID_APPLICATION\"。

请在 scripts/release.local.env 中把 DEVELOPER_ID_APPLICATION 设置为钥匙串里的完整证书名称，例如：
  DEVELOPER_ID_APPLICATION=\"Developer ID Application: Your Name (TEAMID)\"

当前可见的代码签名身份：
$identities"
  fi

  if [[ "$matched_identity" != *"Developer ID Application:"* ]]; then
    fail "当前匹配到的签名身份不是 Developer ID Application 证书：
$matched_identity

本脚本用于外部正式分发，必须使用 Developer ID Application 证书，而不是 Apple Development 证书。"
  fi
}

function read_version_setting() {
  local key="$1"
  awk -v key="$key" '$1 == key && $2 == "=" { print $3; exit }' "$APP_VERSION_CONFIG"
}

function git_repository() {
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s\n' "$GITHUB_REPOSITORY"
    return 0
  fi

  local remote_url
  remote_url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"

  case "$remote_url" in
    git@github.com:*)
      remote_url="${remote_url#git@github.com:}"
      printf '%s\n' "${remote_url%.git}"
      ;;
    https://github.com/*)
      remote_url="${remote_url#https://github.com/}"
      printf '%s\n' "${remote_url%.git}"
      ;;
    ssh://git@github.com/*)
      remote_url="${remote_url#ssh://git@github.com/}"
      printf '%s\n' "${remote_url%.git}"
      ;;
    *)
      printf '%s\n' "$DEFAULT_GITHUB_REPOSITORY"
      ;;
  esac
}

function sparkle_bin_dir() {
  local bin_dir="${SPARKLE_BIN_DIR:-$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin}"
  [[ -x "$bin_dir/sign_update" ]] || fail "未找到 Sparkle 工具链：$bin_dir

请先执行一次 xcodebuild / make build，让 Xcode 拉取 Sparkle 包依赖后再发布。"
  printf '%s\n' "$bin_dir"
}

function sparkle_signature() {
  local dmg_path="$1"
  local bin_dir signature
  bin_dir="$(sparkle_bin_dir)"
  signature="$("$bin_dir/sign_update" --account "${SPARKLE_KEYCHAIN_ACCOUNT:-ed25519}" -p "$dmg_path")" \
    || fail "无法使用 Sparkle EdDSA 私钥为 DMG 签名。

请先运行：
  $(sparkle_bin_dir)/generate_keys

然后允许 Sparkle 访问本机钥匙串中的更新签名密钥。"

  [[ -n "$signature" ]] || fail "Sparkle EdDSA 签名结果为空。"
  printf '%s\n' "$signature"
}

function release_download_url() {
  local repository="$1"
  printf 'https://github.com/%s/releases/download/%s/%s.dmg\n' "$repository" "$TAG" "$APP_NAME"
}

function release_notes_url() {
  local repository="$1"
  printf 'https://github.com/%s/releases/tag/%s\n' "$repository" "$TAG"
}

function write_appcast() {
  local dmg_path="$1"
  local repository download_url notes_url signature file_size pub_date minimum_system_version

  repository="$(git_repository)"
  download_url="$(release_download_url "$repository")"
  notes_url="$(release_notes_url "$repository")"
  signature="$(sparkle_signature "$dmg_path")"
  file_size="$(stat -f '%z' "$dmg_path")"
  pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  minimum_system_version="${SPARKLE_MINIMUM_SYSTEM_VERSION:-14.0}"

  mkdir -p "$DOCS_DIR"

  APP_NAME="$APP_NAME" \
  VERSION="$VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  DOWNLOAD_URL="$download_url" \
  RELEASE_NOTES_URL="$notes_url" \
  PUB_DATE="$pub_date" \
  FILE_SIZE="$file_size" \
  ED_SIGNATURE="$signature" \
  MINIMUM_SYSTEM_VERSION="$minimum_system_version" \
  SPARKLE_NOTES_FILE="$SPARKLE_NOTES_FILE" \
  APPCAST_PATH="$APPCAST_PATH" \
  APP_RELEASE_METADATA_PATH="$APP_RELEASE_METADATA_PATH" \
  python3 <<'PY_APPCAST'
import json
import os
import xml.sax.saxutils as xml
from pathlib import Path

values = {
    key: os.environ[key]
    for key in [
        "APP_NAME",
        "VERSION",
        "BUILD_NUMBER",
        "DOWNLOAD_URL",
        "RELEASE_NOTES_URL",
        "PUB_DATE",
        "FILE_SIZE",
        "ED_SIGNATURE",
        "MINIMUM_SYSTEM_VERSION",
    ]
}
release_notes = Path(os.environ["SPARKLE_NOTES_FILE"]).read_text(encoding="utf-8")
cdata_release_notes = release_notes.replace("]]>", "]]]]><![CDATA[>")

content = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>{xml.escape(values["APP_NAME"])} Releases</title>
        <description>Latest release metadata for {xml.escape(values["APP_NAME"])}.</description>
        <language>en</language>
        <item>
            <title>Version {xml.escape(values["VERSION"])}</title>
            <link>{xml.escape(values["RELEASE_NOTES_URL"])}</link>
            <sparkle:version>{xml.escape(values["BUILD_NUMBER"])}</sparkle:version>
            <sparkle:shortVersionString>{xml.escape(values["VERSION"])}</sparkle:shortVersionString>
            <description sparkle:format="markdown"><![CDATA[{cdata_release_notes}]]></description>
            <sparkle:fullReleaseNotesLink>{xml.escape(values["RELEASE_NOTES_URL"])}</sparkle:fullReleaseNotesLink>
            <pubDate>{xml.escape(values["PUB_DATE"])}</pubDate>
            <enclosure url="{xml.escape(values["DOWNLOAD_URL"])}" length="{xml.escape(values["FILE_SIZE"])}" type="application/octet-stream" sparkle:edSignature="{xml.escape(values["ED_SIGNATURE"])}" />
            <sparkle:minimumSystemVersion>{xml.escape(values["MINIMUM_SYSTEM_VERSION"])}</sparkle:minimumSystemVersion>
        </item>
    </channel>
</rss>
'''
Path(os.environ["APPCAST_PATH"]).write_text(content, encoding="utf-8")
is_prerelease = "-" in values["VERSION"] or any(
    marker in values["VERSION"] for marker in ("beta", "alpha", "rc")
)
if not is_prerelease:
    release_metadata = {
        "version": values["VERSION"],
        "downloadURL": values["DOWNLOAD_URL"],
        "releaseNotesURL": values["RELEASE_NOTES_URL"],
    }
    Path(os.environ["APP_RELEASE_METADATA_PATH"]).write_text(
        json.dumps(release_metadata, indent=2) + "\n",
        encoding="utf-8",
    )
PY_APPCAST

  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$APPCAST_PATH"
  python3 -m json.tool "$APP_RELEASE_METADATA_PATH" >/dev/null

  info "Appcast updated: $APPCAST_PATH"
  if [[ "$VERSION" != *-* && "$VERSION" != *"beta"* && "$VERSION" != *"alpha"* && "$VERSION" != *"rc"* ]]; then
    info "App release metadata updated: $APP_RELEASE_METADATA_PATH"
  fi
}

function ensure_clean_git() {
  local worktree_status
  worktree_status="$(git -C "$ROOT_DIR" status --porcelain)"
  [[ -z "$worktree_status" ]] || fail "Git 工作区必须干净后才能 --publish。"
}

function ensure_tag_ready() {
  local head_commit existing_commit
  head_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"

  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    existing_commit="$(git -C "$ROOT_DIR" rev-list -n 1 "$TAG")"
    if [[ "$existing_commit" != "$head_commit" ]]; then
      [[ "$FORCE" -eq 1 ]] || fail "标签 $TAG 已存在且不指向当前提交，添加 --force 才会重建。"
      git -C "$ROOT_DIR" tag -d "$TAG" >/dev/null
    fi
  fi

  if ! git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    git -C "$ROOT_DIR" tag -a "$TAG" -m "Release $TAG"
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    git -C "$ROOT_DIR" push --force origin "refs/tags/$TAG"
  else
    git -C "$ROOT_DIR" push origin "refs/tags/$TAG"
  fi
}

function sign_path() {
  local path="$1"
  /usr/bin/codesign \
    --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    "$path"
}

function sign_path_preserving_entitlements() {
  local path="$1"
  /usr/bin/codesign \
    --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    --preserve-metadata=entitlements \
    "$path"
}

function sign_path_with_entitlements() {
  local path="$1"
  local entitlements="$2"

  [[ -f "$entitlements" ]] || fail "未找到 entitlements：$entitlements"

  /usr/bin/codesign \
    --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    --entitlements "$entitlements" \
    "$path"
}

function sign_app_path() {
  local path="$1"

  [[ -f "$APP_ENTITLEMENTS" ]] || fail "未找到 app entitlements：$APP_ENTITLEMENTS"

  /usr/bin/codesign \
    --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    --entitlements "$APP_ENTITLEMENTS" \
    "$path"
}

function is_inside_sparkle_framework() {
  local path="$1"
  [[ "$path" == *"/Sparkle.framework" || "$path" == *"/Sparkle.framework/"* ]]
}

function is_right_click_finder_sync_extension() {
  local path="$1"
  [[ "$(basename "$path")" == "RightClickFinderSync.appex" ]]
}

function sign_sparkle_framework() {
  local app_path="$1"
  local sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
  local sparkle_current="$sparkle_framework/Versions/Current"

  [[ -d "$sparkle_framework" ]] || return 0

  if [[ -d "$sparkle_current/XPCServices/Installer.xpc" ]]; then
    sign_path "$sparkle_current/XPCServices/Installer.xpc"
  fi

  if [[ -d "$sparkle_current/XPCServices/Downloader.xpc" ]]; then
    sign_path_preserving_entitlements "$sparkle_current/XPCServices/Downloader.xpc"
  fi

  if [[ -f "$sparkle_current/Autoupdate" ]]; then
    sign_path "$sparkle_current/Autoupdate"
  fi

  if [[ -d "$sparkle_current/Updater.app" ]]; then
    sign_path "$sparkle_current/Updater.app"
  fi

  sign_path "$sparkle_framework"
}

function validate_finder_sync_extension() {
  local app_path="$1"
  local extension_path="$app_path/Contents/PlugIns/RightClickFinderSync.appex"
  local extension_point entitlements

  [[ -d "$extension_path" ]] || fail "未找到 Finder Sync 扩展：$extension_path"

  extension_point="$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$extension_path/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$extension_point" == "com.apple.FinderSync" ]] \
    || fail "Finder Sync 扩展 Info.plist 缺少正确的 NSExtensionPointIdentifier。"

  entitlements="$(/usr/bin/codesign -d --entitlements :- "$extension_path" 2>/dev/null || true)"
  [[ "$entitlements" == *"com.apple.security.app-sandbox"* ]] \
    || fail "Finder Sync 扩展签名缺少 com.apple.security.app-sandbox entitlement。"

  [[ "$entitlements" == *"com.apple.security.temporary-exception.files.home-relative-path.read-only"* ]] \
    || fail "Finder Sync 扩展签名缺少读取右键配置文件所需的 temporary exception entitlement。"
}

function app_bundle_identifier() {
  local app_path="$1"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist" 2>/dev/null \
    || fail "无法从 $app_path 读取 CFBundleIdentifier。"
}

function dmg_signing_identifier() {
  local app_path="$1"

  if [[ -n "${DMG_SIGNING_IDENTIFIER:-}" ]]; then
    printf '%s\n' "$DMG_SIGNING_IDENTIFIER"
    return 0
  fi

  printf '%s\n' "$(app_bundle_identifier "$app_path").disk-image"
}

function sign_app_bundle() {
  local app_path="$1"
  local cli_broker="$app_path/Contents/MacOS/MacToolsCLIBroker"

  [[ -f "$cli_broker" ]] || fail "Release CLI broker is missing: $cli_broker"

  if [[ -d "$app_path/Contents" ]]; then
    while IFS= read -r binary; do
      [[ -n "$binary" ]] || continue
      sign_path "$binary"
    done < <(find "$app_path/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) -print)

    while IFS= read -r bundle; do
      [[ -n "$bundle" ]] || continue
      if is_inside_sparkle_framework "$bundle"; then
        continue
      fi
      if is_right_click_finder_sync_extension "$bundle"; then
        sign_path_with_entitlements "$bundle" "$FINDER_SYNC_ENTITLEMENTS"
      else
        sign_path "$bundle"
      fi
    done < <(find "$app_path/Contents" -depth -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.appex" \) -print)

    sign_sparkle_framework "$app_path"
  fi

  sign_path "$cli_broker"
  sign_app_path "$app_path"
  validate_finder_sync_extension "$app_path"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
}

function sign_disk_image() {
  local dmg_path="$1"
  local identifier="$2"

  /usr/bin/codesign \
    --force \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --timestamp \
    --identifier "$identifier" \
    "$dmg_path"

  /usr/bin/codesign --verify --verbose=2 "$dmg_path"
}

function build_release_app() {
  require_command xcodegen
  require_command "$XCODEBUILD"

  info "Generating Xcode project"
  (cd "$ROOT_DIR" && make generate >/dev/null)

  info "Building Release app version=$VERSION build=$BUILD_NUMBER"
  "$XCODEBUILD" \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    build \
    -quiet
}

function create_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local volume_name="${DMG_VOLUME_NAME:-$APP_NAME}"
  local stage_dir
  stage_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mactools-release-dmg.XXXXXX")"

  ditto "$app_path" "$stage_dir/$APP_NAME.app"
  ln -s /Applications "$stage_dir/Applications"

  info "Creating DMG at $dmg_path"
  hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$stage_dir" \
    -fs HFS+ \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$dmg_path" >/dev/null

  /bin/rm -rf "$stage_dir"
}

function notarize_dmg() {
  local dmg_path="$1"
  [[ -n "${APPLE_NOTARY_PROFILE:-}" ]] || fail "缺少 APPLE_NOTARY_PROFILE，无法公证。"

  info "Submitting DMG for notarization"
  xcrun notarytool submit "$dmg_path" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait

  info "Stapling notarization ticket"
  xcrun stapler staple -v "$dmg_path"
}

function validate_notarized_dmg() {
  local dmg_path="$1"
  local assessment_output

  assessment_output="$(spctl -a -t open --context context:primary-signature -v "$dmg_path" 2>&1)" \
    || fail "Gatekeeper 未接受最终 DMG：
$assessment_output"

  info "Gatekeeper assessment passed"
  printf '%s\n' "$assessment_output"
}

function require_existing_dmg() {
  local dmg_path="$1"
  [[ -f "$dmg_path" ]] || fail "未找到现有 DMG：$dmg_path

如果你想先构建并公证新包，请直接运行：
  ./scripts/release-local.sh

如果你已经做过一次完整发布，请确认要上传的 DMG 仍在上面的路径。"
}

function publish_release() {
  local dmg_path="$1"
  local repository
  repository="$(git_repository)" || fail "无法推断 GitHub 仓库，请在 scripts/release.local.env 中设置 GITHUB_REPOSITORY。"

  require_command gh
  gh auth status >/dev/null 2>&1 || fail "gh 尚未登录，请先运行 gh auth login。"
  ensure_clean_git
  ensure_tag_ready

  if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/mactools-release-notes.XXXXXX.md")"
    python3 "$ROOT_DIR/scripts/changelog.py" extract --tag "$TAG" --output "$NOTES_FILE"
  fi

  SPARKLE_NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/mactools-sparkle-notes.XXXXXX.md")"
  python3 "$ROOT_DIR/scripts/changelog.py" compose-sparkle \
    --tag "$TAG" \
    --app-notes "$NOTES_FILE" \
    --output "$SPARKLE_NOTES_FILE"

  info "Syncing asset to GitHub Release $TAG ($repository)"

  local release_args
  release_args=(--repo "$repository" --title "$APP_NAME $VERSION" --notes-file "$NOTES_FILE")
  if [[ "$VERSION" == *-* || "$VERSION" == *"beta"* || "$VERSION" == *"alpha"* || "$VERSION" == *"rc"* ]]; then
    release_args+=(--prerelease --latest=false)
  else
    release_args+=(--latest)
  fi

  if gh release view "$TAG" --repo "$repository" >/dev/null 2>&1; then
    gh release upload "$TAG" "$dmg_path" --repo "$repository" --clobber
    gh release edit "$TAG" "${release_args[@]}"
  else
    gh release create "$TAG" "$dmg_path" "${release_args[@]}"
  fi
}

require_command ditto
require_command hdiutil
require_command shasum
require_command codesign
require_command git

VERSION="${VERSION:-$(read_version_setting MARKETING_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(read_version_setting CURRENT_PROJECT_VERSION)}"
TAG="${TAG:-v$VERSION}"
NOTES_FILE="${NOTES_FILE:-${GITHUB_RELEASE_NOTES_FILE:-}}"

[[ -n "$VERSION" ]] || fail "无法从 Configs/AppVersion.xcconfig 读取 MARKETING_VERSION。"
[[ -n "$BUILD_NUMBER" ]] || fail "无法从 Configs/AppVersion.xcconfig 读取 CURRENT_PROJECT_VERSION。"
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  fail "Release notes 文件不存在：$NOTES_FILE"
fi
if [[ "$PUBLISH" -eq 1 && "$PUBLISH_EXISTING" -eq 1 ]]; then
  fail "--publish 和 --publish-existing 不能同时使用。"
fi

ARTIFACT_DIR="$ROOT_DIR/build/release/$TAG"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
SIGNED_APP_PATH="$ARTIFACT_DIR/$APP_NAME.app"
DMG_PATH="$ARTIFACT_DIR/$APP_NAME.dmg"
DMG_IDENTIFIER=""
DOCS_DIR="$ROOT_DIR/docs"
APPCAST_PATH="$DOCS_DIR/appcast.xml"
APP_RELEASE_METADATA_PATH="$DOCS_DIR/app-release.json"

mkdir -p "$ARTIFACT_DIR"

if [[ "$PUBLISH_EXISTING" -eq 1 ]]; then
  require_existing_dmg "$DMG_PATH"
  validate_notarized_dmg "$DMG_PATH"
else
  if [[ "$SKIP_BUILD" -eq 0 ]]; then
    build_release_app
  fi

  [[ -d "$APP_PATH" ]] || fail "未找到 Release app：$APP_PATH"

  info "Preparing artifact directory $ARTIFACT_DIR"
  rm -rf "$SIGNED_APP_PATH" "$DMG_PATH"
  ditto "$APP_PATH" "$SIGNED_APP_PATH"

  if [[ "$SKIP_SIGN" -eq 0 ]]; then
    [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] || fail "缺少 DEVELOPER_ID_APPLICATION，无法做正式签名。"
    require_release_signing_identity
    info "Signing app with Developer ID"
    sign_app_bundle "$SIGNED_APP_PATH"
    DMG_IDENTIFIER="$(dmg_signing_identifier "$SIGNED_APP_PATH")"
  else
    info "Skipping code signing"
  fi

  create_dmg "$SIGNED_APP_PATH" "$DMG_PATH"

  if [[ "$SKIP_SIGN" -eq 0 ]]; then
    info "Signing DMG with Developer ID identifier=$DMG_IDENTIFIER"
    sign_disk_image "$DMG_PATH" "$DMG_IDENTIFIER"
  fi

  if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    require_command xcrun
    notarize_dmg "$DMG_PATH"
    validate_notarized_dmg "$DMG_PATH"
  else
    info "Skipping notarization"
  fi
fi

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
info "DMG ready: $DMG_PATH"
info "SHA256: $DMG_SHA256"

if [[ "$PUBLISH" -eq 1 ]]; then
  publish_release "$DMG_PATH"
  write_appcast "$DMG_PATH"
  info "Appcast updated after GitHub Release publish: $APPCAST_PATH"
fi

if [[ "$PUBLISH_EXISTING" -eq 1 ]]; then
  publish_release "$DMG_PATH"
  write_appcast "$DMG_PATH"
  info "Appcast updated after existing artifact publish: $APPCAST_PATH"
fi

if [[ "$PUBLISH" -eq 0 && "$PUBLISH_EXISTING" -eq 0 ]]; then
  info "Skipping appcast update because this run did not publish a GitHub Release."
fi

info "Done"
