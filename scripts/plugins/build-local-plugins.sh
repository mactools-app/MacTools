#!/usr/bin/env bash
set -euo pipefail
ORIGINAL_ARGS=("$@")

if [[ -z "${PYTHON3:-}" ]]; then
    if [[ -x /usr/bin/python3 ]]; then
        PYTHON3=/usr/bin/python3
    else
        PYTHON3=python3
    fi
fi
export PYTHON3

usage() {
    cat <<'USAGE'
Usage:
  build-local-plugins.sh --source-dir Plugins --output-dir build/LocalPlugins [--plugin Demo]...
  build-local-plugins.sh --source-dir Plugins --output-dir build/PluginRelease/Build --configuration Release --skip-catalog

Conventions:
  - A plugin can be an existing .mactoolsplugin directory.
  - Or a plugin source directory can contain plugin.json and the declared bundle.
  - If the declared bundle is missing and the directory has project.yml or *.xcodeproj,
    the script tries to build it with xcodebuild first.
  - --plugin accepts a plugin directory name or plugin ID. It can be repeated or
    passed as a comma-separated list.
  - Set --sign-identity or PLUGIN_CODE_SIGN_IDENTITY to sign packaged bundles.
  - Set --unsigned-build when a later packaging step will sign the bundle.
  - Set --nightly-build-number to derive valid, monotonic source-major.run.attempt
    plugin versions without modifying source plugin.json files.
  - Set --xcodebuild or XCODEBUILD to override the xcodebuild executable.
  - Set --products-dir to reuse bundles from an existing same-configuration
    aggregate build instead of invoking xcodebuild once per plugin.

Generated output:
  build/LocalPlugins/
    Packages/*.mactoolsplugin
    catalog.dev.json unless --skip-catalog is set
USAGE
}

SOURCE_DIR=""
OUTPUT_DIR=""
PLUGIN_FILTERS=()
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-}"
XCODEBUILD_COMMAND="${XCODEBUILD:-}"
SIGN_IDENTITY="${PLUGIN_CODE_SIGN_IDENTITY:-}"
SKIP_CATALOG=0
UNSIGNED_BUILD=0
NIGHTLY_BUILD_NUMBER=""
PRODUCTS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            SOURCE_DIR="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --plugin)
            IFS=',' read -r -a raw_plugin_filters <<< "${2:-}"
            for raw_plugin_filter in "${raw_plugin_filters[@]}"; do
                raw_plugin_filter="${raw_plugin_filter#"${raw_plugin_filter%%[![:space:]]*}"}"
                raw_plugin_filter="${raw_plugin_filter%"${raw_plugin_filter##*[![:space:]]}"}"
                [[ -n "$raw_plugin_filter" ]] && PLUGIN_FILTERS+=("$raw_plugin_filter")
            done
            shift 2
            ;;
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --destination)
            DESTINATION="${2:-}"
            shift 2
            ;;
        --xcodebuild)
            XCODEBUILD_COMMAND="${2:-}"
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY="${2:-}"
            shift 2
            ;;
        --skip-catalog)
            SKIP_CATALOG=1
            shift
            ;;
        --unsigned-build)
            UNSIGNED_BUILD=1
            shift
            ;;
        --nightly-build-number)
            NIGHTLY_BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --products-dir)
            PRODUCTS_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$CONFIGURATION" == "Nightly" && -z "$NIGHTLY_BUILD_NUMBER" ]]; then
    echo "--nightly-build-number is required for Nightly plugin packaging." >&2
    exit 1
fi
if [[ "$CONFIGURATION" != "Nightly" && -n "$NIGHTLY_BUILD_NUMBER" ]]; then
    echo "--nightly-build-number is only valid with --configuration Nightly." >&2
    exit 1
fi

if [[ -z "$SOURCE_DIR" || -z "$OUTPUT_DIR" ]]; then
    usage >&2
    exit 1
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd -P || true)"
if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
    echo "Plugin source directory not found. Expected: $SOURCE_DIR" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OFFICIAL_PLUGIN_SOURCE_DIR="$(cd "$REPO_ROOT/Plugins" && pwd -P)"
THIRD_PARTY_NOTICE_MANIFEST="$REPO_ROOT/Sources/Resources/ThirdPartyNotices/manifest.json"
THIRD_PARTY_NOTICE_GENERATOR="$REPO_ROOT/scripts/licenses/generate-third-party-notices.py"
if [[ -z "$XCODEBUILD_COMMAND" ]]; then
    XCODEBUILD_COMMAND="$REPO_ROOT/scripts/xcodebuild-filtered.sh"
fi
cache_args=(--source-dir "$SOURCE_DIR" --output-dir "$OUTPUT_DIR"
    --configuration "$CONFIGURATION" --destination "$DESTINATION" --xcodebuild "$XCODEBUILD_COMMAND")
[[ "$UNSIGNED_BUILD" == "1" ]] && cache_args+=(--unsigned-build)
# Validate before resetting Packages, including when a cache root was misconfigured inside it.
"$PYTHON3" "$REPO_ROOT/scripts/plugins/with-build-cache.py" --check-paths "${cache_args[@]}"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
PACKAGES_DIR="$OUTPUT_DIR/Packages"
DERIVED_DATA_DIR="${MACTOOLS_PLUGIN_DERIVED_ROOT:-}"
CATALOG_PATH="$OUTPUT_DIR/catalog.dev.json"

rm -rf "$PACKAGES_DIR"
mkdir -p "$PACKAGES_DIR"

json_value() {
    local file="$1"
    local expression="$2"
    python3 - "$file" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
data = json.load(open(path))
value = data
for part in expression.split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    print("")
else:
    print(value)
PY
}

copy_manifest_for_configuration() {
    local source="$1"
    local destination="$2"
    local copy_args=(
        copy
        --source "$source"
        --destination "$destination"
        --configuration "$CONFIGURATION"
        --app-version-config "$REPO_ROOT/Configs/AppVersion.xcconfig"
    )
    if [[ -n "$NIGHTLY_BUILD_NUMBER" ]]; then
        copy_args+=(--nightly-build-number "$NIGHTLY_BUILD_NUMBER")
    fi
    "$PYTHON3" "$REPO_ROOT/scripts/plugins/copy-plugin-manifest.py" "${copy_args[@]}"
}

discover_candidates() {
    if [[ -d "$SOURCE_DIR" && "$SOURCE_DIR" == *.mactoolsplugin ]]; then
        printf '%s\n' "$SOURCE_DIR"
        return
    fi

    if [[ -f "$SOURCE_DIR/plugin.json" ]]; then
        printf '%s\n' "$SOURCE_DIR"
        return
    fi

    find "$SOURCE_DIR" -maxdepth 3 \( -name plugin.json -o -name '*.mactoolsplugin' \) -print \
        | while IFS= read -r path; do
            if [[ "$path" == *.mactoolsplugin ]]; then
                printf '%s\n' "$path"
            else
                dirname "$path"
            fi
        done \
        | sort -u
}

matches_filter() {
    local candidate="$1"

    if [[ ${#PLUGIN_FILTERS[@]} -eq 0 ]]; then
        return 0
    fi

    local basename
    basename="$(basename "$candidate")"
    basename="${basename%.mactoolsplugin}"

    local id=""
    if [[ -f "$candidate/plugin.json" ]]; then
        id="$(json_value "$candidate/plugin.json" "id")"
    fi

    local filter
    for filter in "${PLUGIN_FILTERS[@]}"; do
        [[ "$basename" == "$filter" ]] && return 0
        [[ -n "$id" && "$id" == "$filter" ]] && return 0
    done

    return 1
}

project_file_for() {
    local root="$1"
    local manifest="$2"
    local output_var="$3"

    local configured_project
    configured_project="$(json_value "$manifest" "build.project")"
    [[ -z "$configured_project" ]] && configured_project="$(json_value "$manifest" "buildProject")"
    if [[ -n "$configured_project" ]]; then
        local project_path
        if [[ "$configured_project" = /* ]]; then
            project_path="$configured_project"
        else
            project_path="$(cd "$root" && cd "$(dirname "$configured_project")" && printf '%s/%s\n' "$(pwd)" "$(basename "$configured_project")")"
        fi
        printf -v "$output_var" '%s' "$project_path"
        return
    fi

    if [[ -f "$root/project.yml" ]]; then
        if ! (cd "$root" && xcodegen generate >/dev/null); then
            echo "Failed to generate Xcode project for $root." >&2
            return 1
        fi
    fi

    local project_path
    project_path="$(find "$root" -maxdepth 1 -name '*.xcodeproj' -print | sort | head -1)"
    printf -v "$output_var" '%s' "$project_path"
}

scheme_for() {
    local root="$1"
    local project="$2"
    local manifest="$3"
    local output_var="$4"

    local candidate_scheme
    candidate_scheme="$(json_value "$manifest" "build.scheme")"
    [[ -n "$candidate_scheme" ]] && { printf -v "$output_var" '%s' "$candidate_scheme"; return; }

    candidate_scheme="$(json_value "$manifest" "buildScheme")"
    [[ -n "$candidate_scheme" ]] && { printf -v "$output_var" '%s' "$candidate_scheme"; return; }

    local root_name
    root_name="$(basename "$root")"
    if "$XCODEBUILD_COMMAND" -list -project "$project" 2>/dev/null | grep -q "^[[:space:]]*$root_name$"; then
        printf -v "$output_var" '%s' "$root_name"
        return
    fi

    candidate_scheme="$("$XCODEBUILD_COMMAND" -list -json -project "$project" 2>/dev/null \
        | python3 -c 'import json,sys; data=json.load(sys.stdin); print((data.get("project") or {}).get("schemes", [""])[0])')"
    printf -v "$output_var" '%s' "$candidate_scheme"
}

build_bundle_if_needed() {
    local root="$1"
    local manifest="$2"
    local bundle_relative_path="$3"
    local bundle_name="$4"
    local output_var="$5"

    if [[ -d "$root/$bundle_relative_path" ]]; then
        printf -v "$output_var" '%s' "$root/$bundle_relative_path"
        return
    fi

    if [[ -n "$PRODUCTS_DIR" && -d "$PRODUCTS_DIR/$bundle_name" ]]; then
        printf -v "$output_var" '%s' "$PRODUCTS_DIR/$bundle_name"
        return
    fi

    # Prebuilt/aggregate products keep their existing path; only fallback compiles need a cache owner.
    if [[ "${MACTOOLS_PLUGIN_CACHE_CHECKOUT:-}" != "$REPO_ROOT" ]]; then
        exec "$PYTHON3" "$REPO_ROOT/scripts/plugins/with-build-cache.py" "${cache_args[@]}" -- "${ORIGINAL_ARGS[@]}"
    fi

    local project
    project_file_for "$root" "$manifest" project
    if [[ -z "$project" ]]; then
        echo "Bundle not found and no Xcode project exists: $root/$bundle_relative_path" >&2
        return 1
    fi

    local scheme
    scheme_for "$root" "$project" "$manifest" scheme
    if [[ -z "$scheme" ]]; then
        echo "Unable to infer xcodebuild scheme for $root" >&2
        return 1
    fi

    local derived_data
    local project_key
    project_key="$("$PYTHON3" - "$project" "$scheme" <<'PY'
import hashlib, json, pathlib, sys
print(hashlib.sha256(json.dumps([str(pathlib.Path(sys.argv[1]).resolve()), sys.argv[2]]).encode()).hexdigest()[:24])
PY
)"
    derived_data="$DERIVED_DATA_DIR/$project_key"

    local build_args=(
        -project "$project"
        -scheme "$scheme"
        -configuration "$CONFIGURATION"
        -derivedDataPath "$derived_data"
    )
    if [[ -n "$DESTINATION" ]]; then
        build_args+=(-destination "$DESTINATION")
    fi
    if [[ "$UNSIGNED_BUILD" == "1" ]]; then
        build_args+=(
            CODE_SIGNING_ALLOWED=NO
            CODE_SIGNING_REQUIRED=NO
            CODE_SIGN_IDENTITY=
        )
    fi
    if ! "$XCODEBUILD_COMMAND" "${build_args[@]}" build -quiet; then
        echo "Failed to build plugin bundle '$scheme' for $root." >&2
        return 1
    fi

    local settings_file="$MACTOOLS_PLUGIN_BUILD_REPORT/$project_key-build-settings.json"
    "$XCODEBUILD_COMMAND" "${build_args[@]}" -showBuildSettings -json > "$settings_file"
    local built_bundle
    # Retained products may include obsolete targets or paths. Use the current scheme's declared product.
    built_bundle="$("$PYTHON3" - "$settings_file" "$bundle_name" "$derived_data" <<'PY'
import json, pathlib, sys
settings_file, name, derived = sys.argv[1:]
settings = json.load(open(settings_file))
paths = {pathlib.Path(entry['buildSettings']['TARGET_BUILD_DIR']) / name
         for entry in settings if entry.get('buildSettings', {}).get('FULL_PRODUCT_NAME') == name}
if len(paths) != 1:
    sys.exit('Current scheme must declare exactly one product for ' + name)
product = paths.pop().resolve()
if pathlib.Path(derived).resolve() not in product.parents or not product.is_dir():
    sys.exit('Current product is missing or outside managed compiler storage: ' + str(product))
print(product)
PY
)"

    printf -v "$output_var" '%s' "$built_bundle"
}

package_source_dir() {
    local root="$1"
    local output_var="$2"
    local manifest="$root/plugin.json"

    if [[ ! -f "$manifest" ]]; then
        echo "Missing plugin.json: $root" >&2
        return 1
    fi

    local plugin_id
    local bundle_relative_path
    local bundle_name
    plugin_id="$(json_value "$manifest" "id")"
    bundle_relative_path="$(json_value "$manifest" "bundleRelativePath")"
    bundle_name="$(basename "$bundle_relative_path")"

    if [[ -z "$plugin_id" || -z "$bundle_relative_path" ]]; then
        echo "plugin.json must include id and bundleRelativePath: $manifest" >&2
        return 1
    fi

    local bundle_path
    build_bundle_if_needed "$root" "$manifest" "$bundle_relative_path" "$bundle_name" bundle_path

    local package_path="$PACKAGES_DIR/$plugin_id.mactoolsplugin"
    rm -rf "$package_path"
    mkdir -p "$package_path/$(dirname "$bundle_relative_path")"
    copy_manifest_for_configuration "$manifest" "$package_path/plugin.json"
    ditto "$bundle_path" "$package_path/$bundle_relative_path"
    if [[ "$root" == "$OFFICIAL_PLUGIN_SOURCE_DIR/"* ]]; then
        "$PYTHON3" "$THIRD_PARTY_NOTICE_GENERATOR" \
            --manifest "$THIRD_PARTY_NOTICE_MANIFEST" \
            --repo-root "$REPO_ROOT" \
            --product "plugin:$plugin_id" \
            --output "$package_path/THIRD_PARTY_NOTICES.txt"
    fi

    if [[ -n "$SIGN_IDENTITY" ]]; then
        "$REPO_ROOT/scripts/plugins/sign-plugin-package.sh" \
            --package "$package_path" \
            --identity "$SIGN_IDENTITY"
    fi

    [[ -d "$package_path" ]] || { echo "Failed to create plugin package: $package_path" >&2; return 1; }
    printf -v "$output_var" '%s' "$package_path"
}

copy_package_dir() {
    local package="$1"
    local output_var="$2"
    local package_name
    package_name="$(basename "$package")"
    local destination="$PACKAGES_DIR/$package_name"
    rm -rf "$destination"
    "$REPO_ROOT/scripts/plugins/build-plugin-package.sh" \
        --source "$package" \
        --output-dir "$PACKAGES_DIR" >/dev/null
    printf -v "$output_var" '%s' "$destination"
}

packages=()
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    matches_filter "$candidate" || continue

    if [[ "$candidate" == *.mactoolsplugin ]]; then
        built_package_path=""
        copy_package_dir "$candidate" built_package_path
        packages+=("$built_package_path")
    else
        built_package_path=""
        package_source_dir "$candidate" built_package_path
        packages+=("$built_package_path")
    fi
done < <(discover_candidates)

if [[ ${#packages[@]} -eq 0 ]]; then
    if [[ ${#PLUGIN_FILTERS[@]} -gt 0 ]]; then
        echo "No plugin matched requested filters in $SOURCE_DIR: ${PLUGIN_FILTERS[*]}" >&2
    else
        echo "No plugins found in $SOURCE_DIR." >&2
    fi
    exit 1
fi

if [[ "$SKIP_CATALOG" != "1" ]]; then
    catalog_args=()
    for package in "${packages[@]}"; do
        catalog_args+=(--package "$package")
    done

    "$REPO_ROOT/scripts/plugins/generate-plugin-catalog.sh" \
        --mode debug \
        --output "$CATALOG_PATH" \
        --plugins-root "$SOURCE_DIR" \
        --allow-sparse-legacy \
        "${catalog_args[@]}"
fi

echo "Built ${#packages[@]} plugin package(s)."
if [[ "$SKIP_CATALOG" != "1" ]]; then
    echo "Catalog: $CATALOG_PATH"
fi
