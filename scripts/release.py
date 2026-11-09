#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
APP_VERSION_CONFIG = ROOT_DIR / "Configs" / "AppVersion.xcconfig"
CHANGELOG_PATH = ROOT_DIR / "CHANGELOG.md"
RELEASE_HISTORY_PATH = ROOT_DIR / "Sources" / "Resources" / "ReleaseHistory.json"
CHANGELOG_FRAGMENT_DIR = ROOT_DIR / "changes" / "unreleased"
PLUGIN_SOURCE_DIR = ROOT_DIR / "Plugins"
PLUGIN_SHARED_PATHS = [ROOT_DIR / "Sources/MacToolsPluginKit"]
LEGACY_PLUGIN_CATALOG = ROOT_DIR / "docs/plugins/catalog.json"
PLUGIN_PLAN_PATH = ROOT_DIR / "build/release/plugin-plan.json"
APP_PLUGIN_CATALOG_PREFLIGHT = (
    ROOT_DIR / "scripts/plugins/preflight-app-plugin-catalog.swift"
)
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
APP_TAG_RE = re.compile(r"^v(\d+\.\d+\.\d+)$")
PLUGIN_TAG_RE = re.compile(r"^plugins-(\d+\.\d+\.\d+)$")


class ReleaseError(RuntimeError):
    pass


@dataclass(frozen=True)
class PluginInfo:
    id: str
    directory_name: str
    display_name: str
    path: Path
    manifest_path: Path
    version: str
    plugin_kit_version: int


@dataclass(frozen=True)
class PluginAnalysis:
    mode: str
    selected_ids: list[str]
    removed_ids: list[str]
    needs_bump: list[PluginInfo]
    already_bumped: list[PluginInfo]
    new_plugins: list[PluginInfo]
    reasons: dict[str, list[str]]

    @property
    def release_required(self) -> bool:
        return bool(
            self.selected_ids
            or self.removed_ids
            or self.needs_bump
            or self.already_bumped
            or self.new_plugins
        )


def info(message: str) -> None:
    print(f"[release] {message}", flush=True)


def fail(message: str) -> None:
    raise ReleaseError(message)


def run(
    args: list[str],
    *,
    cwd: Path = ROOT_DIR,
    capture: bool = False,
    dry_run: bool = False,
    mutates: bool = False,
) -> subprocess.CompletedProcess[str]:
    if dry_run and mutates:
        print("+ " + " ".join(shell_quote(part) for part in args))
        return subprocess.CompletedProcess(args, 0, "" if capture else None, "")

    sys.stdout.flush()
    sys.stderr.flush()

    kwargs: dict[str, object] = {
        "cwd": cwd,
        "text": True,
        "check": False,
    }
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE

    result = subprocess.run(args, **kwargs)
    if result.returncode != 0:
        if capture and result.stderr:
            sys.stderr.write(result.stderr)
        command = " ".join(shell_quote(part) for part in args)
        fail(f"命令失败：{command}")
    return result


def shell_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:=@%+,-]+", value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def git(args: list[str], *, capture: bool = True) -> str:
    result = run(["git", *args], capture=capture)
    return (result.stdout or "").strip()


def require_command(command: str) -> None:
    if shutil.which(command) is None:
        fail(f"缺少必要命令：{command}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Interactive release helper for MacTools app and plugin releases."
    )
    parser.add_argument("--type", choices=["app", "plugin"], help="发布类型。")
    parser.add_argument("--version", help="目标版本，不含 v 或 plugins- 前缀。")
    parser.add_argument("--level", choices=["patch", "minor", "major"], help="版本递增级别。")
    parser.add_argument(
        "--plugin-mode",
        choices=["auto", "selected", "all"],
        default=None,
        help="插件发布模式，默认 auto。",
    )
    parser.add_argument(
        "--plugin",
        action="append",
        default=[],
        help="插件 ID 或目录名；可重复，也可用逗号分隔。仅用于 --plugin-mode selected。",
    )
    parser.add_argument("--remote", default="origin", help="Git remote，默认 origin。")
    parser.add_argument("--branch", default="main", help="发布分支，默认 main。")
    parser.add_argument("--yes", action="store_true", help="跳过最终确认。")
    parser.add_argument("--skip-check", action="store_true", help="跳过本地轻量检查。")
    parser.add_argument("--dry-run", action="store_true", help="只展示将执行的写操作。")
    return parser.parse_args()


def read_interactive_line(prompt: str) -> str:
    sys.stdout.write(prompt)
    sys.stdout.flush()

    fd = sys.stdin.fileno()
    previous_settings = termios.tcgetattr(fd)
    value: list[str] = []

    try:
        tty.setcbreak(fd)
        while True:
            char = sys.stdin.read(1)
            if char == "":
                sys.stdout.write("\n")
                fail("已取消发布。")
            if char == "\x1b":
                sys.stdout.write("\n")
                fail("已取消发布。")
            if char in {"\r", "\n"}:
                sys.stdout.write("\n")
                return "".join(value)
            if char in {"\x03", "\x04"}:
                sys.stdout.write("\n")
                fail("已取消发布。")
            if char in {"\x7f", "\b"}:
                if value:
                    value.pop()
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
                continue
            if char == "\x15":
                while value:
                    value.pop()
                    sys.stdout.write("\b \b")
                sys.stdout.flush()
                continue
            if char.isprintable():
                value.append(char)
                sys.stdout.write(char)
                sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, previous_settings)


def prompt_choice(title: str, choices: list[tuple[str, str]]) -> str:
    if not sys.stdin.isatty():
        fail(f"非交互环境需要通过参数指定：{title}")

    print(title)
    for index, (_, label) in enumerate(choices, start=1):
        print(f"  {index}. {label}")

    while True:
        raw = read_interactive_line("> ").strip()
        if not raw:
            return choices[0][0]
        if raw.isdigit():
            index = int(raw)
            if 1 <= index <= len(choices):
                return choices[index - 1][0]
        for value, label in choices:
            if raw == value or raw == label:
                return value
        print("请输入列表中的编号或值，或按 Esc 退出。")


def prompt_text(title: str) -> str:
    if not sys.stdin.isatty():
        fail(f"非交互环境需要通过参数指定：{title}")
    while True:
        raw = read_interactive_line(f"{title}\n> ").strip()
        if raw:
            return raw
        print("输入不能为空，或按 Esc 退出。")


def confirm(
    message: str,
    assume_yes: bool,
    *,
    noninteractive_error: str | None = None,
) -> None:
    if assume_yes:
        return
    if not sys.stdin.isatty():
        fail(noninteractive_error or "非交互环境需要传入 --yes。")
    while True:
        raw = read_interactive_line(f"{message} [y/N] ").strip().lower()
        if raw in {"y", "yes"}:
            return
        if raw in {"n", "no"}:
            fail("已取消发布。")
        print("请输入 y 确认，n 取消，或按 Esc 退出。")


def ensure_clean_worktree() -> None:
    status = git(["status", "--porcelain"])
    if status:
        fail(
            "发布前 Git 工作区必须干净。请先提交或暂存当前改动。\n"
            + status
        )


def warn_dirty_worktree_for_dry_run() -> None:
    status = git(["status", "--porcelain"])
    if status:
        info("Dry-run: 当前工作区有未提交改动，正式发布前仍需要清理。")


def ensure_release_branch(branch: str) -> None:
    current_branch = git(["branch", "--show-current"])
    if current_branch != branch:
        fail(f"当前分支是 {current_branch or '(detached)'}，请切到 {branch} 后再发布。")


def fetch_release_refs(remote: str, dry_run: bool) -> None:
    info(f"Fetching release refs from {remote}")
    run(["git", "fetch", "--prune", "--tags", remote], dry_run=dry_run, mutates=True)


def sync_branch_after_confirm(remote: str, branch: str, dry_run: bool) -> None:
    info(f"Rebasing local commits onto {remote}/{branch}")
    command = ["git", "pull", "--rebase", remote, branch]
    if dry_run:
        run(command, dry_run=dry_run, mutates=True)
    else:
        result = subprocess.run(command, cwd=ROOT_DIR, text=True, check=False)
        if result.returncode != 0:
            fail(
                "同步远端失败。若 rebase 发生冲突，请解决冲突后执行 "
                "`git rebase --continue`，或执行 `git rebase --abort` 回到发布前状态后重新运行 make release。"
            )
    if dry_run:
        warn_dirty_worktree_for_dry_run()
    else:
        ensure_clean_worktree()


def semver_tuple(version: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        fail(f"版本号必须是 x.y.z 格式：{version}")
    return tuple(int(part) for part in match.groups())


def format_semver(value: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in value)


def bump_version(version: str, level: str) -> str:
    major, minor, patch = semver_tuple(version)
    if level == "major":
        return f"{major + 1}.0.0"
    if level == "minor":
        return f"{major}.{minor + 1}.0"
    if level == "patch":
        return f"{major}.{minor}.{patch + 1}"
    fail(f"未知版本级别：{level}")


def normalize_requested_version(version: str | None) -> str | None:
    if version is None:
        return None
    normalized = version.strip()
    if normalized.startswith("plugins-"):
        normalized = normalized.removeprefix("plugins-")
    elif normalized.startswith("v"):
        normalized = normalized.removeprefix("v")
    semver_tuple(normalized)
    return normalized


def infer_bump_level(base_version: str, target_version: str) -> str:
    base = semver_tuple(base_version)
    target = semver_tuple(target_version)
    if target <= base:
        fail(f"目标版本必须高于当前基准版本：{base_version} -> {target_version}")
    if target[0] > base[0]:
        return "major"
    if target[1] > base[1]:
        return "minor"
    return "patch"


def max_version(values: list[str], fallback: str) -> str:
    if not values:
        return fallback
    return format_semver(max(semver_tuple(value) for value in values))


def compare_versions(lhs: str, rhs: str) -> int:
    left = semver_tuple(lhs)
    right = semver_tuple(rhs)
    if left < right:
        return -1
    if left > right:
        return 1
    return 0


def latest_tag_version(pattern: str, tag_re: re.Pattern[str]) -> str | None:
    raw = git(["tag", "--list", pattern])
    versions = []
    for tag in raw.splitlines():
        match = tag_re.fullmatch(tag.strip())
        if match:
            versions.append(match.group(1))
    if not versions:
        return None
    return max_version(versions, "0.0.0")


def read_app_versions() -> tuple[str, int]:
    content = APP_VERSION_CONFIG.read_text(encoding="utf-8")
    marketing = re.search(r"(?m)^\s*MARKETING_VERSION\s*=\s*([^\s#]+)", content)
    build = re.search(r"(?m)^\s*CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)", content)
    if not marketing or not build:
        fail("无法从 Configs/AppVersion.xcconfig 读取 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION。")
    return marketing.group(1), int(build.group(1))


def write_app_versions(version: str, build_number: int, dry_run: bool) -> None:
    if dry_run:
        print(f"+ update Configs/AppVersion.xcconfig MARKETING_VERSION={version} CURRENT_PROJECT_VERSION={build_number}")
        return

    content = APP_VERSION_CONFIG.read_text(encoding="utf-8")
    content, marketing_count = re.subn(
        r"(?m)^(\s*MARKETING_VERSION\s*=\s*)[^\s#]+",
        rf"\g<1>{version}",
        content,
        count=1,
    )
    content, build_count = re.subn(
        r"(?m)^(\s*CURRENT_PROJECT_VERSION\s*=\s*)[0-9]+",
        rf"\g<1>{build_number}",
        content,
        count=1,
    )
    if marketing_count != 1 or build_count != 1:
        fail("更新 Configs/AppVersion.xcconfig 版本号失败。")
    APP_VERSION_CONFIG.write_text(content, encoding="utf-8")


def read_plugins() -> dict[str, PluginInfo]:
    plugins: dict[str, PluginInfo] = {}
    for manifest_path in sorted(PLUGIN_SOURCE_DIR.glob("*/plugin.json")):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        plugin_id = manifest["id"]
        plugins[plugin_id] = PluginInfo(
            id=plugin_id,
            directory_name=manifest_path.parent.name,
            display_name=manifest.get("displayName", plugin_id),
            path=manifest_path.parent,
            manifest_path=manifest_path,
            version=manifest["version"],
            plugin_kit_version=manifest["pluginKitVersion"],
        )
    return plugins


def plugin_catalog_path(plugin_kit_version: int) -> Path:
    if plugin_kit_version == 2:
        return LEGACY_PLUGIN_CATALOG
    if plugin_kit_version == 5:
        return ROOT_DIR / "docs/plugins/v5/schema3/catalog.json"
    return ROOT_DIR / "docs" / "plugins" / f"v{plugin_kit_version}" / "catalog.json"


def same_abi_catalog_migration_baseline_path(plugin_kit_version: int) -> Path | None:
    if plugin_kit_version == 5:
        return ROOT_DIR / "docs/plugins/v5/catalog.json"
    return None


def previous_plugin_catalog_path() -> Path:
    plugin_kit_version = current_plugin_kit_version(read_plugins())
    preferred_path = plugin_catalog_path(plugin_kit_version)
    if preferred_path.exists() or preferred_path == LEGACY_PLUGIN_CATALOG:
        return preferred_path

    same_abi_baseline = same_abi_catalog_migration_baseline_path(plugin_kit_version)
    if same_abi_baseline is not None and same_abi_baseline.exists():
        return same_abi_baseline

    previous_versioned_catalogs = []
    for candidate in (ROOT_DIR / "docs" / "plugins").glob("v*/catalog.json"):
        match = re.fullmatch(r"v(\d+)", candidate.parent.name)
        if match and int(match.group(1)) < plugin_kit_version and candidate.exists():
            previous_versioned_catalogs.append((int(match.group(1)), candidate))
    if previous_versioned_catalogs:
        return max(previous_versioned_catalogs, key=lambda item: item[0])[1]

    # The first v3 release compares against the immutable v2 catalog. Once a
    # versioned catalog exists, subsequent releases stay within the newest
    # available ABI line.
    return LEGACY_PLUGIN_CATALOG


def read_previous_catalog() -> dict:
    catalog_path = previous_plugin_catalog_path()
    if not catalog_path.exists():
        return {}
    return json.loads(catalog_path.read_text(encoding="utf-8"))


def load_previous_catalog() -> dict[str, dict]:
    catalog = read_previous_catalog()
    return {entry["id"]: entry for entry in catalog.get("plugins", [])}


def current_plugin_kit_version(plugins: dict[str, PluginInfo]) -> int:
    versions = sorted({plugin.plugin_kit_version for plugin in plugins.values()})
    if len(versions) != 1:
        fail(
            "插件 manifest 必须使用同一个 pluginKitVersion："
            + ", ".join(str(version) for version in versions)
        )
    return versions[0]


def ensure_plugin_kit_releasable(plugin_kit_version: int) -> None:
    if plugin_kit_version < 5:
        fail(
            "PluginKit 5 之前的 catalog 已冻结，不能使用当前 schema-3 流程发布。"
        )


def plugin_release_tag(entry: dict) -> str | None:
    package = entry.get("package") or {}
    candidates = [package.get("url") or "", entry.get("releaseNotesURL") or ""]
    for value in candidates:
        match = re.search(r"/releases/(?:download|tag)/([^/]+)", value)
        if match:
            return match.group(1)
    return None


def git_ref_exists(ref: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", ref],
        cwd=ROOT_DIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.returncode == 0


def changed_paths_since(ref: str, path: Path) -> list[str]:
    raw = git(["diff", "--name-only", f"{ref}..HEAD", "--", path.relative_to(ROOT_DIR).as_posix()])
    result = []
    for item in raw.splitlines():
        parts = Path(item).parts
        if "Tests" in parts:
            continue
        result.append(item)
    return result


def plugin_package_relevant_changes_since(ref: str, plugin: PluginInfo) -> list[str]:
    paths = [plugin.path, *PLUGIN_SHARED_PATHS]
    return [
        changed_path
        for path in paths
        for changed_path in changed_paths_since(ref, path)
    ]


def confirm_plugin_kit_changes_before_release() -> None:
    latest_app_version = latest_tag_version("v*", APP_TAG_RE)
    if latest_app_version is None:
        return

    latest_app_tag = f"v{latest_app_version}"
    changed_paths = list(
        dict.fromkeys(
            changed_path
            for path in PLUGIN_SHARED_PATHS
            for changed_path in changed_paths_since(latest_app_tag, path)
        )
    )
    if not changed_paths:
        return

    print()
    print(f"检测到自 {latest_app_tag} 以来 PluginKit 代码有变化：")
    for path in changed_paths:
        print(f"  - {path}")
    print("这些改动可能影响已发布插件的二进制兼容性。")
    confirm(
        "确认已检查这些 PluginKit 改动是否需要提升 pluginKitVersion，并继续发布？",
        False,
        noninteractive_error=(
            "检测到 PluginKit 代码变化，非交互发布无法完成兼容性确认。"
            "请在交互终端运行 `make release`，检查 pluginKitVersion 后确认。"
        ),
    )


def normalize_plugin_selection(raw_values: list[str], plugins: dict[str, PluginInfo]) -> list[str]:
    values: list[str] = []
    for raw in raw_values:
        values.extend(part.strip() for part in raw.split(",") if part.strip())

    by_directory = {plugin.directory_name: plugin_id for plugin_id, plugin in plugins.items()}
    selected: list[str] = []
    unknown: list[str] = []
    for value in values:
        plugin_id = value if value in plugins else by_directory.get(value)
        if plugin_id is None:
            unknown.append(value)
        elif plugin_id not in selected:
            selected.append(plugin_id)

    if unknown:
        fail("未知插件：" + ", ".join(unknown))
    return selected


def analyze_plugins(mode: str, selection: list[str]) -> PluginAnalysis:
    plugins = read_plugins()
    plugin_kit_version = current_plugin_kit_version(plugins)
    previous_catalog = read_previous_catalog()
    previous_catalog_plugin_kit_version = previous_catalog.get("pluginKitVersion")
    previous_entries = load_previous_catalog()
    reasons: dict[str, list[str]] = {}
    selected_ids: list[str] = []
    needs_bump: list[PluginInfo] = []
    already_bumped: list[PluginInfo] = []
    new_plugins: list[PluginInfo] = []
    removed_ids: list[str] = []
    errors: list[str] = []

    def select(plugin: PluginInfo, reason: str) -> None:
        if plugin.id not in selected_ids:
            selected_ids.append(plugin.id)
        reasons.setdefault(plugin.id, []).append(reason)

    def previous_entry_plugin_kit_version(entry: dict) -> int:
        if "pluginKitVersion" in entry:
            return entry["pluginKitVersion"]
        if previous_catalog_plugin_kit_version is not None:
            return previous_catalog_plugin_kit_version
        fail(f"生产 catalog 条目缺少 pluginKitVersion：{entry.get('id', '(unknown)')}")

    def handle_plugin_kit_change(plugin: PluginInfo, previous_entry: dict, version_cmp: int) -> bool:
        previous_version = previous_entry_plugin_kit_version(previous_entry)
        if previous_version == plugin.plugin_kit_version:
            return False

        reason = f"pluginKitVersion {previous_version} -> {plugin.plugin_kit_version}"
        if version_cmp > 0:
            already_bumped.append(plugin)
        else:
            needs_bump.append(plugin)
        select(plugin, reason)
        return True

    if mode == "selected":
        selected_ids = normalize_plugin_selection(selection, plugins)
        if (
            previous_catalog_plugin_kit_version is not None
            and previous_catalog_plugin_kit_version != plugin_kit_version
            and set(selected_ids) != set(plugins)
        ):
            errors.append(
                "当前 PluginKit 版本和生产 catalog 不一致 "
                f"({previous_catalog_plugin_kit_version} -> {plugin_kit_version})。"
                "请使用 plugin-mode all 全量重建插件，避免 catalog 混合不兼容插件包。"
            )
        for plugin_id in selected_ids:
            reasons.setdefault(plugin_id, []).append("selected mode")
    elif mode == "all":
        for plugin_id, plugin in sorted(plugins.items()):
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is None:
                new_plugins.append(plugin)
            else:
                previous_version = previous_entry["version"]
                if semver_tuple(plugin.version) < semver_tuple(previous_version):
                    errors.append(
                        f"{plugin_id}: version cannot go backwards "
                        f"({previous_version} -> {plugin.version})"
                    )
                    continue
                handle_plugin_kit_change(
                    plugin,
                    previous_entry,
                    compare_versions(plugin.version, previous_version),
                )
                if (
                    semver_tuple(plugin.version) > semver_tuple(previous_version)
                    and previous_entry_plugin_kit_version(previous_entry) == plugin.plugin_kit_version
                ):
                    already_bumped.append(plugin)
            select(plugin, "all mode")
    elif not previous_entries:
        for plugin_id, plugin in sorted(plugins.items()):
            new_plugins.append(plugin)
            select(plugin, "no previous catalog")
    else:
        removed_ids = sorted(set(previous_entries) - set(plugins))
        for plugin_id, plugin in sorted(plugins.items()):
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is None:
                new_plugins.append(plugin)
                select(plugin, "new plugin")
                continue

            previous_version = previous_entry["version"]
            current_version = plugin.version
            if semver_tuple(current_version) < semver_tuple(previous_version):
                errors.append(
                    f"{plugin_id}: version cannot go backwards "
                    f"({previous_version} -> {current_version})"
                )
                continue
            if handle_plugin_kit_change(
                plugin,
                previous_entry,
                compare_versions(current_version, previous_version),
            ):
                continue
            if semver_tuple(current_version) > semver_tuple(previous_version):
                already_bumped.append(plugin)
                select(plugin, f"version {previous_version} -> {current_version}")
                continue

            tag = plugin_release_tag(previous_entry)
            if not tag:
                errors.append(f"{plugin_id}: previous release tag could not be inferred from catalog")
                continue
            if not git_ref_exists(tag):
                errors.append(f"{plugin_id}: previous release tag is not available locally: {tag}")
                continue

            changed = plugin_package_relevant_changes_since(tag, plugin)
            if changed:
                needs_bump.append(plugin)
                select(plugin, f"package-relevant changes since {tag}")

    if mode == "selected":
        for plugin_id in selected_ids:
            plugin = plugins[plugin_id]
            previous_entry = previous_entries.get(plugin_id)
            if previous_entry is None:
                new_plugins.append(plugin)
                continue

            previous_version = previous_entry["version"]
            if semver_tuple(plugin.version) < semver_tuple(previous_version):
                errors.append(
                    f"{plugin_id}: version cannot go backwards "
                    f"({previous_version} -> {plugin.version})"
                )
                continue
            if handle_plugin_kit_change(
                plugin,
                previous_entry,
                compare_versions(plugin.version, previous_version),
            ):
                continue
            if semver_tuple(plugin.version) > semver_tuple(previous_version):
                already_bumped.append(plugin)
                continue

            tag = plugin_release_tag(previous_entry)
            changed = (
                plugin_package_relevant_changes_since(tag, plugin)
                if tag and git_ref_exists(tag)
                else []
            )
            if changed:
                needs_bump.append(plugin)

    if errors:
        fail("\n".join(errors))

    deduped_selected = sorted(dict.fromkeys(selected_ids))
    deduped_needs_bump = list({plugin.id: plugin for plugin in needs_bump}.values())
    deduped_already_bumped = list({plugin.id: plugin for plugin in already_bumped}.values())
    deduped_new_plugins = list({plugin.id: plugin for plugin in new_plugins}.values())

    return PluginAnalysis(
        mode=mode,
        selected_ids=deduped_selected,
        removed_ids=removed_ids,
        needs_bump=deduped_needs_bump,
        already_bumped=deduped_already_bumped,
        new_plugins=deduped_new_plugins,
        reasons={plugin_id: reasons.get(plugin_id, []) for plugin_id in deduped_selected},
    )


def write_plugin_versions(plugins: list[PluginInfo], level: str, dry_run: bool) -> dict[str, str]:
    updated: dict[str, str] = {}
    for plugin in plugins:
        next_version = bump_version(plugin.version, level)
        updated[plugin.id] = next_version
        if dry_run:
            print(f"+ update {plugin.manifest_path.relative_to(ROOT_DIR)} version={next_version}")
            continue

        manifest = json.loads(plugin.manifest_path.read_text(encoding="utf-8"))
        manifest["version"] = next_version
        plugin.manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    return updated


def refresh_plugins(plugins: list[PluginInfo]) -> list[PluginInfo]:
    latest = read_plugins()
    return [latest[plugin.id] for plugin in plugins]


def plugins_requiring_version_bump(mode: str, analysis: PluginAnalysis) -> list[PluginInfo]:
    if mode == "auto":
        return analysis.needs_bump

    plugins = read_plugins()
    previous_entries = load_previous_catalog()
    result: list[PluginInfo] = []
    for plugin_id in analysis.selected_ids:
        plugin = plugins[plugin_id]
        previous_entry = previous_entries.get(plugin_id)
        if previous_entry is None:
            continue
        if semver_tuple(plugin.version) == semver_tuple(previous_entry["version"]):
            result.append(plugin)
    return result


def check_tag_available(tag: str, remote: str) -> None:
    if git_ref_exists(f"refs/tags/{tag}"):
        fail(f"本地 tag 已存在：{tag}")
    result = subprocess.run(
        ["git", "ls-remote", "--exit-code", "--tags", remote, f"refs/tags/{tag}"],
        cwd=ROOT_DIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode == 0:
        fail(f"远端 tag 已存在：{tag}")
    if result.returncode not in {0, 2}:
        fail(f"无法检查远端 tag：{tag}")


def run_app_check(skip_check: bool, dry_run: bool) -> None:
    if skip_check:
        info("Skipping app check")
        return
    if os.environ.get("CI") == "true":
        info("Running CI app check")
        run(["make", "generate"], dry_run=dry_run, mutates=True)
        run(
            [
                "xcodebuild",
                "-project",
                "MacTools.xcodeproj",
                "-scheme",
                "MacTools",
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS",
                "-derivedDataPath",
                "build/DerivedData",
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGN_IDENTITY=",
                "test",
                "-quiet",
            ],
            dry_run=dry_run,
            mutates=True,
        )
    else:
        info("Running app build check")
        run(["make", "build"], dry_run=dry_run, mutates=True)


def changelog_fragment_paths(release: str) -> list[Path]:
    if not CHANGELOG_FRAGMENT_DIR.exists():
        return []
    paths: list[Path] = []
    release_pattern = re.compile(rf"(?m)^\s*release\s*:\s*['\"]?{re.escape(release)}['\"]?\s*$")
    for path in sorted(CHANGELOG_FRAGMENT_DIR.glob("*.md")):
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        if release_pattern.search(content):
            paths.append(path)
    return paths


def changelog_status_label(release: str) -> str:
    count = len(changelog_fragment_paths(release))
    if count == 1:
        return f"1 pending {release} fragment"
    return f"{count} pending {release} fragments"


def validate_changelog(release: str, require_pending: bool) -> None:
    command = ["python3", "scripts/changelog.py", "validate", "--release", release]
    if require_pending:
        command.append("--require-pending")
    run(command)


def prepare_changelog(release: str, tag: str, dry_run: bool) -> list[Path]:
    paths = [CHANGELOG_PATH, RELEASE_HISTORY_PATH, *changelog_fragment_paths(release)]
    info(f"Preparing CHANGELOG.md for {tag}")
    command = ["python3", "scripts/changelog.py", "prepare", "--release", release, "--tag", tag]
    if dry_run:
        command.append("--dry-run")
    run(command, dry_run=False)
    return paths


def run_plugin_generate_check(skip_check: bool, dry_run: bool) -> None:
    if skip_check:
        info("Skipping plugin check")
        return
    info("Running plugin project generation check")
    run(["make", "generate"], dry_run=dry_run, mutates=True)


def prepare_plugin_website_data(dry_run: bool) -> list[Path]:
    info("Regenerating website plugin data for the release")
    run(
        ["python3", "scripts/plugins/generate_website_plugin_data.py"],
        cwd=ROOT_DIR,
        dry_run=dry_run,
        mutates=True,
    )
    paths = [
        ROOT_DIR / "site/src/generated/plugins.json",
        ROOT_DIR / "site/src/generated/actions.json",
    ]
    assets = ROOT_DIR / "site/public/generated/plugin-assets"
    if assets.exists() and (
        any(assets.iterdir())
        or git(["ls-files", "--", "site/public/generated/plugin-assets"])
    ):
        paths.append(assets)
    return paths


def run_plugin_plan_check(mode: str, selection: list[str], skip_check: bool, dry_run: bool) -> None:
    if skip_check:
        return
    info("Running plugin release plan check")
    plan_args = [
        "scripts/plugins/plan-plugin-release.py",
        "--mode",
        mode,
        "--source-dir",
        "Plugins",
        "--previous-catalog",
        previous_plugin_catalog_path().relative_to(ROOT_DIR).as_posix(),
        "--output",
        PLUGIN_PLAN_PATH.relative_to(ROOT_DIR).as_posix(),
    ]
    if mode == "selected" and selection:
        plan_args.extend(["--plugins", ",".join(selection)])
    run(plan_args, dry_run=dry_run, mutates=True)


def commit_if_needed(paths: list[Path], message: str, dry_run: bool) -> bool:
    relative_paths = [path.relative_to(ROOT_DIR).as_posix() for path in paths]
    if not relative_paths:
        return False
    if dry_run:
        print("+ git add " + " ".join(shell_quote(path) for path in relative_paths))
        print("+ git commit -m " + shell_quote(message))
        return True
    run(["git", "add", "--all", "--", *relative_paths], dry_run=dry_run, mutates=True)
    staged = git(["diff", "--cached", "--name-only"])
    if not staged:
        info("No version file changes to commit")
        return False
    run(["git", "commit", "-m", message], dry_run=dry_run, mutates=True)
    return True


def push_branch_and_tag(remote: str, branch: str, tag: str, dry_run: bool) -> None:
    run(["git", "push", remote, f"HEAD:{branch}"], dry_run=dry_run, mutates=True)
    run(["git", "tag", "-a", tag, "-m", f"Release {tag}"], dry_run=dry_run, mutates=True)
    run(["git", "push", remote, tag], dry_run=dry_run, mutates=True)


def choose_release_type(value: str | None) -> str:
    if value:
        return value
    return prompt_choice(
        "选择发布类型（回车默认 app）：",
        [
            ("app", "app - 发布 MacTools DMG"),
            ("plugin", "plugin - 发布插件批次"),
        ],
    )


def choose_plugin_mode(value: str | None, explicit_plugins: list[str]) -> tuple[str, list[str]]:
    if explicit_plugins:
        return "selected", explicit_plugins

    if value:
        mode = value
    elif sys.stdin.isatty():
        mode = prompt_choice(
            "选择插件发布模式（回车默认 auto）：",
            [
                ("auto", "auto - 自动发布变化插件"),
                ("selected", "selected - 指定插件"),
                ("all", "all - 全量重建插件包"),
            ],
        )
    else:
        mode = "auto"

    if mode != "selected":
        return mode, []

    raw_selection = prompt_text("输入插件 ID 或目录名，多个用逗号分隔：")
    return mode, [raw_selection]


def choose_level(value: str | None, base_version: str, title: str) -> str:
    if value:
        return value
    return prompt_choice(
        title,
        [
            ("patch", f"patch -> {bump_version(base_version, 'patch')}"),
            ("minor", f"minor -> {bump_version(base_version, 'minor')}"),
            ("major", f"major -> {bump_version(base_version, 'major')}"),
        ],
    )


def summarize_plugin_analysis(analysis: PluginAnalysis) -> None:
    if analysis.needs_bump:
        info(
            "需要自动 bump 的插件："
            + ", ".join(f"{plugin.id} {plugin.version}" for plugin in analysis.needs_bump)
        )
    if analysis.already_bumped:
        info(
            "已手动 bump 的插件："
            + ", ".join(f"{plugin.id} {plugin.version}" for plugin in analysis.already_bumped)
        )
    if analysis.new_plugins:
        info("新插件：" + ", ".join(plugin.id for plugin in analysis.new_plugins))
    if analysis.removed_ids:
        info("将从 catalog 移除：" + ", ".join(analysis.removed_ids))


def app_check_label(skip_check: bool) -> str:
    if skip_check:
        return "skip"
    if os.environ.get("CI") == "true":
        return "make generate + xcodebuild test"
    return "make build"


def resolve_app_release_target(
    current_version: str,
    latest_tag: str | None,
    requested_version: str | None,
    requested_level: str | None,
) -> tuple[str, str, bool]:
    baseline_version = latest_tag or current_version
    uses_declared_version = False

    if requested_version:
        next_version = requested_version
        if latest_tag and compare_versions(next_version, latest_tag) <= 0:
            fail(f"目标版本必须高于最新 app tag：{latest_tag} -> {next_version}")
        if compare_versions(next_version, current_version) < 0:
            fail(
                "目标版本不能低于 AppVersion.xcconfig 已声明的版本："
                f"{current_version} -> {next_version}"
            )
        level = requested_level or infer_bump_level(baseline_version, requested_version)
    elif requested_level:
        level = requested_level
        next_version = bump_version(baseline_version, level)
    elif latest_tag and compare_versions(current_version, latest_tag) > 0:
        level = infer_bump_level(latest_tag, current_version)
        next_version = current_version
        uses_declared_version = True
    else:
        level = choose_level(
            None,
            baseline_version,
            "选择 app 版本递增级别（回车默认 patch）：",
        )
        next_version = bump_version(baseline_version, level)

    if latest_tag and compare_versions(next_version, latest_tag) <= 0:
        fail(f"目标版本必须高于最新 app tag：{latest_tag} -> {next_version}")
    if compare_versions(next_version, current_version) < 0:
        fail(
            "目标版本不能低于 AppVersion.xcconfig 已声明的版本："
            f"{current_version} -> {next_version}"
        )

    return next_version, level, uses_declared_version


def preflight_app_plugin_catalog(app_version: str) -> None:
    info("验证目标版本所需的生产插件列表。")
    run(
        [
            "xcrun",
            "swift",
            str(APP_PLUGIN_CATALOG_PREFLIGHT.relative_to(ROOT_DIR)),
            "--app-version",
            app_version,
        ]
    )


def release_app(args: argparse.Namespace) -> None:
    validate_changelog("app", require_pending=True)
    current_version, current_build = read_app_versions()
    latest_tag = latest_tag_version("v*", APP_TAG_RE)
    requested_version = normalize_requested_version(args.version)
    next_version, level, uses_declared_version = resolve_app_release_target(
        current_version,
        latest_tag,
        requested_version,
        args.level,
    )
    next_build = current_build + 1
    tag = f"v{next_version}"
    check_tag_available(tag, args.remote)

    print()
    print("App 发布计划")
    print(f"  当前 AppVersion.xcconfig: {current_version} ({current_build})")
    print(f"  最新 app tag: {latest_tag or '(none)'}")
    print(f"  下一版本: {next_version} ({next_build})")
    if uses_declared_version:
        print("  版本来源: AppVersion.xcconfig 已预声明")
    print(f"  tag: {tag}")
    print(f"  check: {app_check_label(args.skip_check)}")
    print(f"  changelog: {changelog_status_label('app')}")
    confirm("确认执行 bump、check、commit、tag 和 push？", args.yes)

    sync_branch_after_confirm(args.remote, args.branch, args.dry_run)
    validate_changelog("app", require_pending=True)
    current_version_after_sync, current_build_after_sync = read_app_versions()
    latest_tag_after_sync = latest_tag_version("v*", APP_TAG_RE)
    resolve_app_release_target(
        current_version_after_sync,
        latest_tag_after_sync,
        next_version,
        level,
    )
    next_build = current_build_after_sync + 1
    check_tag_available(tag, args.remote)
    preflight_app_plugin_catalog(next_version)
    run_app_check(args.skip_check, args.dry_run)
    write_app_versions(next_version, next_build, args.dry_run)
    changelog_paths = prepare_changelog("app", tag, args.dry_run)
    commit_if_needed([APP_VERSION_CONFIG, *changelog_paths], f"chore: release {tag}", args.dry_run)
    push_branch_and_tag(args.remote, args.branch, tag, args.dry_run)
    info(f"App release tag pushed: {tag}")


def release_plugin(args: argparse.Namespace) -> None:
    mode, raw_selection = choose_plugin_mode(args.plugin_mode, args.plugin)
    plugins = read_plugins()
    current_plugin_kit = current_plugin_kit_version(plugins)
    ensure_plugin_kit_releasable(current_plugin_kit)
    previous_catalog = read_previous_catalog()
    previous_plugin_kit = previous_catalog.get("pluginKitVersion")
    is_compatibility_migration = (
        not plugin_catalog_path(current_plugin_kit).exists()
        and same_abi_catalog_migration_baseline_path(current_plugin_kit)
        == previous_plugin_catalog_path()
    )
    if is_compatibility_migration:
        if mode == "selected":
            fail(
                "检测到同一 PluginKit ABI 的 catalog schema 迁移。"
                "plugin-mode selected 不能只发布部分插件；"
                "请使用 plugin-mode all 全量重建并提升所有插件版本。"
            )
        if mode == "auto":
            mode = "all"
            info(
                "检测到同一 PluginKit ABI 的 catalog schema 迁移，"
                "插件发布模式自动切换为 all。"
            )
    elif mode == "auto" and previous_plugin_kit is not None and previous_plugin_kit != current_plugin_kit:
        mode = "all"
        info(
            f"检测到 PluginKit ABI 升级（{previous_plugin_kit} -> {current_plugin_kit}），"
            "插件发布模式自动切换为 all。"
        )
    selection = normalize_plugin_selection(raw_selection, plugins) if raw_selection else []
    analysis = analyze_plugins(mode, selection)
    if not analysis.release_required:
        fail("未检测到需要发布的插件变化。若要强制发布，请使用 ARGS=\"--type plugin --plugin-mode all\"。")
    validate_changelog("plugin", require_pending=True)

    latest_batch = latest_tag_version("plugins-*", PLUGIN_TAG_RE)
    base_version = latest_batch or "0.0.0"
    requested_version = normalize_requested_version(args.version)
    if requested_version:
        level = args.level or infer_bump_level(base_version, requested_version)
        next_batch = requested_version
    else:
        level = choose_level(args.level, base_version, "选择插件批次版本递增级别（回车默认 patch）：")
        next_batch = bump_version(base_version, level)
    tag = f"plugins-{next_batch}"
    check_tag_available(tag, args.remote)

    print()
    print("Plugin 发布计划")
    print(f"  mode: {mode}")
    print(f"  最新插件批次 tag: {'plugins-' + latest_batch if latest_batch else '(none)'}")
    print(f"  下一批次 tag: {tag}")
    print(f"  将发布插件: {', '.join(analysis.selected_ids) if analysis.selected_ids else '(catalog-only)'}")
    print(f"  check: {'skip' if args.skip_check else 'make generate + plan-plugin-release'}")
    print(f"  changelog: {changelog_status_label('plugin')}")
    summarize_plugin_analysis(analysis)
    plugins_to_bump = plugins_requiring_version_bump(mode, analysis)
    if plugins_to_bump:
        print(
            "  将自动 bump: "
            + ", ".join(f"{plugin.id} {plugin.version} -> {bump_version(plugin.version, level)}" for plugin in plugins_to_bump)
        )
    confirm("确认执行 bump、check、commit、tag 和 push？", args.yes)

    sync_branch_after_confirm(args.remote, args.branch, args.dry_run)
    validate_changelog("plugin", require_pending=True)
    latest_batch_after_sync = latest_tag_version("plugins-*", PLUGIN_TAG_RE)
    if requested_version and semver_tuple(next_batch) <= semver_tuple(latest_batch_after_sync or "0.0.0"):
        fail(f"同步远端后目标插件批次不再高于基准版本：{latest_batch_after_sync} -> {next_batch}")
    if not requested_version:
        expected_batch_after_sync = bump_version(latest_batch_after_sync or "0.0.0", level)
        if expected_batch_after_sync != next_batch:
            fail(
                "同步远端后计算出的下一插件批次发生变化："
                f"{next_batch} -> {expected_batch_after_sync}。请重新运行 make release。"
            )
    analysis = analyze_plugins(mode, selection)
    plugins_to_bump = plugins_requiring_version_bump(mode, analysis)
    check_tag_available(tag, args.remote)
    updated_versions = write_plugin_versions(plugins_to_bump, level, args.dry_run)
    if updated_versions:
        info(
            "已更新插件版本："
            + ", ".join(f"{plugin_id} -> {version}" for plugin_id, version in updated_versions.items())
        )

    if updated_versions:
        analysis = analyze_plugins(mode, selection)
        plugins_to_bump = refresh_plugins(plugins_to_bump)

    website_paths = prepare_plugin_website_data(args.dry_run)
    run_plugin_generate_check(args.skip_check, args.dry_run)
    run_plugin_plan_check(mode, selection, args.skip_check, args.dry_run)
    changelog_paths = prepare_changelog("plugin", tag, args.dry_run)
    changed_manifests = [plugin.manifest_path for plugin in plugins_to_bump]
    made_commit = commit_if_needed(
        [*changed_manifests, *website_paths, *changelog_paths],
        f"chore: release {tag}",
        args.dry_run,
    )
    if not made_commit and not args.dry_run:
        head = git(["rev-parse", "--short", "HEAD"])
        info(f"No version bump commit needed; tagging current HEAD {head}.")
    push_branch_and_tag(args.remote, args.branch, tag, args.dry_run)
    info(f"Plugin release tag pushed: {tag}")


def main() -> int:
    args = parse_args()
    try:
        require_command("git")
        require_command("make")
        ensure_release_branch(args.branch)
        if args.dry_run:
            warn_dirty_worktree_for_dry_run()
        else:
            ensure_clean_worktree()
        fetch_release_refs(args.remote, args.dry_run)
        confirm_plugin_kit_changes_before_release()
        release_type = choose_release_type(args.type)
        if release_type == "app":
            release_app(args)
        else:
            release_plugin(args)
    except ReleaseError as error:
        print(f"[release] error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
