#!/usr/bin/env python3
"""Validation and projection for checked-in MacTools plugin manifests."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import re
import struct
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse


SUPPORTED_LOCALE_ORDER = (
    "ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "tr", "zh-Hans", "zh-Hant"
)
SUPPORTED_LOCALES = frozenset(SUPPORTED_LOCALE_ORDER)
SUPPORTED_LOCALE_SET = SUPPORTED_LOCALES
BASE_LOCALIZED_REFERENCES = {"@displayName", "@summary"}
LOCALIZABLE_STRING_REFERENCE_PREFIX = "@localizable."
STANDARD_ACTION_REFERENCE_PREFIX = "@standardAction."
STANDARD_SETUP_REFERENCE_PREFIX = "@standardSetup."
PRODUCT_STRING_REFERENCE_PREFIX = "@productStrings."
STANDARD_ACTION_TEMPLATES = {
    "toggle.title": {
        "ar": "تبديل حالة {displayName}", "de": "{displayName} umschalten",
        "en": "Toggle {displayName}", "es": "Alternar {displayName}",
        "fr": "Activer ou désactiver {displayName}", "ja": "{displayName}を切り替える",
        "ko": "{displayName} 전환", "pt": "Alternar {displayName}",
        "ru": "Переключить «{displayName}»", "tr": "{displayName} Durumunu Değiştir",
        "zh-Hans": "切换{displayName}",
        "zh-Hant": "切換{displayName}",
    },
    "toggle.description": {
        "ar": "بدّل حالة «{displayName}» بين التشغيل والإيقاف.",
        "de": "Schaltet „{displayName}“ ein oder aus.",
        "en": "Switch {displayName} between on and off.",
        "es": "Activa o desactiva {displayName}.",
        "fr": "Active ou désactive {displayName}.",
        "ja": "{displayName}のオン／オフを切り替えます。",
        "ko": "{displayName}을(를) 켜거나 끕니다.",
        "pt": "Ativa ou desativa {displayName}.",
        "ru": "Включает или выключает функцию «{displayName}».",
        "tr": "{displayName} özelliğini açar veya kapatır.",
        "zh-Hans": "在开启和关闭之间切换{displayName}。",
        "zh-Hant": "在開啟和關閉之間切換{displayName}。",
    },
    "set-enabled.title": {
        "ar": "تعيين حالة {displayName}", "de": "{displayName}-Status festlegen",
        "en": "Set {displayName} State", "es": "Definir estado de {displayName}",
        "fr": "Définir l’état de {displayName}", "ja": "{displayName}の状態を設定",
        "ko": "{displayName} 상태 설정", "pt": "Definir estado de {displayName}",
        "ru": "Задать состояние «{displayName}»", "tr": "{displayName} Durumunu Ayarla",
        "zh-Hans": "设置{displayName}状态",
        "zh-Hant": "設定{displayName}狀態",
    },
    "set-enabled.description": {
        "ar": "عيّن ما إذا كان «{displayName}» مفعّلًا.",
        "de": "Legt fest, ob „{displayName}“ aktiviert ist.",
        "en": "Set whether {displayName} is enabled.",
        "es": "Define si {displayName} está activado.",
        "fr": "Définit si {displayName} est activé.",
        "ja": "{displayName}を有効にするかどうかを設定します。",
        "ko": "{displayName}의 활성화 여부를 설정합니다.",
        "pt": "Define se {displayName} está ativado.",
        "ru": "Определяет, включена ли функция «{displayName}».",
        "tr": "{displayName} özelliğinin etkin olup olmadığını ayarlar.",
        "zh-Hans": "设置是否启用{displayName}。",
        "zh-Hant": "設定是否啟用{displayName}。",
    },
}
STANDARD_SETUP_TEMPLATES = {
    "requirements.title": {
        "ar": "إعداد {displayName}", "de": "{displayName} einrichten",
        "en": "Set Up {displayName}", "es": "Configurar {displayName}",
        "fr": "Configurer {displayName}", "ja": "{displayName}を設定",
        "ko": "{displayName} 설정", "pt": "Configurar {displayName}",
        "ru": "Настройка «{displayName}»", "tr": "{displayName} Kurulumu",
        "zh-Hans": "设置{displayName}",
        "zh-Hant": "設定{displayName}",
    },
    "requirements.description": {
        "ar": "قبل استخدام هذه الإضافة، راجع المتطلبات التالية واستوفها: {requirements}.",
        "de": "Prüfe und erfülle vor der Verwendung dieses Plugins folgende Anforderungen: {requirements}.",
        "en": "Before using this plugin, review and satisfy these requirements: {requirements}.",
        "es": "Antes de usar este plugin, revisa y cumple estos requisitos: {requirements}.",
        "fr": "Avant d’utiliser ce module, vérifiez et remplissez les conditions suivantes : {requirements}.",
        "ja": "このプラグインを使用する前に、次の要件を確認して満たしてください：{requirements}。",
        "ko": "이 플러그인을 사용하기 전에 다음 요구 사항을 확인하고 충족하세요: {requirements}.",
        "pt": "Antes de usar este plugin, revise e cumpra estes requisitos: {requirements}.",
        "ru": "Перед использованием плагина проверьте и выполните следующие требования: {requirements}.",
        "tr": "Bu eklentiyi kullanmadan önce şu gereksinimleri gözden geçirin ve karşılayın: {requirements}.",
        "zh-Hans": "使用此插件前，请检查并满足以下要求：{requirements}。",
        "zh-Hant": "使用此外掛程式前，請檢查並滿足以下要求：{requirements}。",
    },
}


def _localized_requirement(
    en: str,
    *,
    ar: str,
    de: str,
    es: str,
    fr: str,
    ja: str,
    ko: str,
    pt: str,
    ru: str,
    tr: str,
    zh_hans: str,
    zh_hant: str,
) -> dict[str, str]:
    return {
        "ar": ar, "de": de, "en": en, "es": es, "fr": fr, "ja": ja,
        "ko": ko, "pt": pt, "ru": ru, "tr": tr, "zh-Hans": zh_hans, "zh-Hant": zh_hant,
    }


LOCALIZED_REQUIREMENT_NAMES = {
    "accessibility": _localized_requirement(
        "Accessibility permission", ar="إذن تسهيلات الاستخدام", de="Bedienungshilfen-Berechtigung",
        es="permiso de Accesibilidad", fr="autorisation Accessibilité", ja="アクセシビリティ権限",
        ko="손쉬운 사용 권한", pt="permissão de Acessibilidade", ru="доступ к Универсальному доступу",
        tr="Erişilebilirlik izni", zh_hans="辅助功能权限", zh_hant="輔助使用權限",
    ),
    "automation": _localized_requirement(
        "Automation permission", ar="إذن الأتمتة", de="Automation-Berechtigung",
        es="permiso de Automatización", fr="autorisation Automatisation", ja="オートメーション権限",
        ko="자동화 권한", pt="permissão de Automação", ru="доступ к Автоматизации",
        tr="Otomasyon izni", zh_hans="自动化权限", zh_hant="自動化權限",
    ),
    "calendarFullAccess": _localized_requirement(
        "Full Calendar Access", ar="وصول كامل إلى التقويم", de="Vollzugriff auf Kalender",
        es="acceso total al Calendario", fr="accès complet au calendrier", ja="カレンダーへのフルアクセス",
        ko="캘린더 전체 접근", pt="acesso total ao Calendário", ru="полный доступ к Календарю",
        tr="Tam Takvim Erişimi", zh_hans="日历完全访问权限", zh_hant="行事曆完整取用權限",
    ),
    "inputMonitoring": _localized_requirement(
        "Input Monitoring permission", ar="إذن مراقبة الإدخال", de="Eingabeüberwachung-Berechtigung",
        es="permiso de Monitorización de entrada", fr="autorisation Surveillance de l’entrée",
        ja="入力監視権限", ko="입력 모니터링 권한", pt="permissão de Monitoramento de Entrada",
        ru="доступ к Мониторингу ввода", tr="Giriş İzleme izni",
        zh_hans="输入监控权限", zh_hant="輸入監控權限",
    ),
    "screen-recording": _localized_requirement(
        "Screen Recording permission", ar="إذن تسجيل الشاشة", de="Bildschirmaufnahme-Berechtigung",
        es="permiso de Grabación de pantalla", fr="autorisation Enregistrement de l’écran",
        ja="画面収録権限", ko="화면 기록 권한", pt="permissão de Gravação de Tela",
        ru="доступ к Записи экрана", tr="Ekran Kaydı izni",
        zh_hans="屏幕录制权限", zh_hant="螢幕錄製權限",
    ),
    "system-audio-recording": _localized_requirement(
        "System Audio Recording permission", ar="إذن تسجيل صوت النظام",
        de="Systemaudioaufnahme-Berechtigung", es="permiso de grabación de audio del sistema",
        fr="autorisation d’enregistrement audio du système", ja="システムオーディオ録音権限",
        ko="시스템 오디오 녹음 권한", pt="permissão de gravação de áudio do sistema",
        ru="доступ к записи системного аудио", tr="Sistem Sesi Kaydı izni",
        zh_hans="系统音频录制权限", zh_hant="系統音訊錄製權限",
    ),
    "full-disk-access": _localized_requirement(
        "Full Disk Access", ar="الوصول الكامل إلى القرص", de="Festplattenvollzugriff",
        es="acceso total al disco", fr="accès complet au disque", ja="フルディスクアクセス",
        ko="전체 디스크 접근", pt="acesso total ao disco", ru="полный доступ к диску",
        tr="Tam Disk Erişimi", zh_hans="完全磁盘访问", zh_hant="完整磁碟存取",
    ),
    "built-in battery": _localized_requirement(
        "built-in battery", ar="بطارية مدمجة", de="integrierter Akku", es="batería integrada",
        fr="batterie intégrée", ja="内蔵バッテリー", ko="내장 배터리", pt="bateria integrada",
        ru="встроенный аккумулятор", tr="yerleşik pil",
        zh_hans="内置电池", zh_hant="內建電池",
    ),
    "connected display": _localized_requirement(
        "connected display", ar="شاشة متصلة", de="angeschlossenes Display", es="pantalla conectada",
        fr="écran connecté", ja="接続済みディスプレイ", ko="연결된 디스플레이",
        pt="monitor conectado", ru="подключённый дисплей", tr="bağlı ekran",
        zh_hans="已连接的显示器", zh_hant="已連接的顯示器",
    ),
    "controllable system fans": _localized_requirement(
        "controllable system fans", ar="مراوح نظام قابلة للتحكم", de="steuerbare Systemlüfter",
        es="ventiladores del sistema controlables", fr="ventilateurs système contrôlables",
        ja="制御可能なシステムファン", ko="제어 가능한 시스템 팬", pt="ventoinhas do sistema controláveis",
        ru="управляемые системные вентиляторы", tr="denetlenebilir sistem fanları",
        zh_hans="可控制的系统风扇", zh_hant="可控制的系統風扇",
    ),
    "Sidecar-compatible Mac and display": _localized_requirement(
        "Sidecar-compatible Mac and display", ar="جهاز Mac وشاشة متوافقان مع Sidecar",
        de="Sidecar-kompatibler Mac und Bildschirm", es="Mac y pantalla compatibles con Sidecar",
        fr="Mac et écran compatibles avec Sidecar", ja="Sidecar 対応の Mac とディスプレイ",
        ko="Sidecar 호환 Mac 및 디스플레이", pt="Mac e monitor compatíveis com Sidecar",
        ru="Mac и дисплей с поддержкой Sidecar", tr="Sidecar uyumlu Mac ve ekran",
        zh_hans="支持 Sidecar 的 Mac 和显示器",
        zh_hant="支援 Sidecar 的 Mac 和顯示器",
    ),
}
VALID_CATEGORIES = {
    "display", "audio", "system", "storage", "productivity", "monitoring", "other"
}
VALID_PERMISSION_IDS = {
    "accessibility", "automation", "calendarFullAccess", "inputMonitoring",
    "screen-recording", "system-audio-recording", "full-disk-access"
}
VALID_SURFACES = {
    "unified-search", "global-shortcut", "run-link", "workflow", "automatic-rule",
    "action-grid", "trackpad-gesture", "app-intent", "manual"
}
VALID_RISKS = {"safe", "confirmationRequired"}
VALID_EXTERNAL_POLICIES = {"unavailable", "allowed", "confirmAlways", "configurable"}
VALID_PROVIDER_KINDS = {"static", "dynamic", "mixed"}
VALID_PARAMETER_KINDS = {"boolean", "integer", "double", "string"}
VALID_PORTABILITY = {"portable", "localOnly"}
VALID_ARCHITECTURES = {"arm64", "x86_64"}
VALID_SETUP_COMPLEXITIES = {"none", "simple", "guided", "advanced"}
VALID_NETWORK_USE = {"none", "optional", "required"}
VALID_TELEMETRY = {"none", "optional", "required"}
VALID_RETENTION = {"none", "session", "until-disabled", "until-uninstalled", "user-controlled"}
VALID_SETTINGS_CAPABILITIES = {"none", "form", "workspace"}
# This is the metadata-format floor, not the current host ABI version.
PRODUCT_METADATA_REQUIRED_PLUGIN_KIT_VERSION = 5
MAX_ASSET_BYTES = 10 * 1024 * 1024
MAX_ASSET_DIMENSION = 7680
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PLUGIN_IDENTIFIER_PATTERN = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]{1,126}[A-Za-z0-9]$"
)
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
NIGHTLY_BUILD_PATTERN = re.compile(r"^([0-9]+)\.([0-9]+)$")
DOMAIN_PATTERN = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,63}$"
)


class ManifestValidationError(ValueError):
    pass


@dataclass(frozen=True)
class AssetProjection:
    source: Path
    catalog: dict


def validate_nightly_build_number(value: str) -> tuple[str, str]:
    match = NIGHTLY_BUILD_PATTERN.fullmatch(value)
    if match is None:
        raise ManifestValidationError(
            "Nightly build number must use numeric run.attempt components"
        )
    return match.group(1), match.group(2)


def apply_nightly_package_overrides(
    manifest: dict,
    nightly_build_number: str | None = None,
) -> None:
    plugin_id = manifest.get("id")
    if plugin_id in {"fan-control", "battery-charge-limit"}:
        stable_path = (
            "/Library/PrivilegedHelperTools/cc.ggbond.mactools."
            f"{plugin_id}.smc-helper"
        )
        nightly_path = stable_path + ".nightly"
        for step in manifest.get("setup", {}).get("steps", []):
            if step.get("id") != "install-privileged-helper":
                continue
            step["description"] = {
                locale: (
                    description
                    if nightly_path in description
                    else description.replace(stable_path, nightly_path)
                )
                for locale, description in step["description"].items()
            }

    if nightly_build_number is None:
        return

    source_version = str(manifest.get("version", ""))
    if VERSION_PATTERN.fullmatch(source_version) is None:
        raise ManifestValidationError(
            "source plugin version must contain one to three numeric components"
        )
    run_number, run_attempt = validate_nightly_build_number(nightly_build_number)
    source_major = source_version.split(".", 1)[0]
    manifest["version"] = f"{source_major}.{run_number}.{run_attempt}"


def _localized_source_fields(manifest: dict):
    presentation = manifest.get("presentation")
    if isinstance(presentation, dict):
        if "longDescription" in presentation:
            yield "presentation.longDescription", presentation["longDescription"]
        examples = presentation.get("examples")
        if isinstance(examples, list):
            for index, example in enumerate(examples):
                if isinstance(example, dict) and "text" in example:
                    yield f"presentation.examples[{index}].text", example["text"]
        screenshots = presentation.get("screenshots")
        if isinstance(screenshots, list):
            for index, screenshot in enumerate(screenshots):
                if isinstance(screenshot, dict) and "alt" in screenshot:
                    yield f"presentation.screenshots[{index}].alt", screenshot["alt"]

    discovery = manifest.get("discovery")
    if isinstance(discovery, dict):
        use_cases = discovery.get("useCases")
        if isinstance(use_cases, list):
            for index, use_case in enumerate(use_cases):
                if isinstance(use_case, dict) and "title" in use_case:
                    yield f"discovery.useCases[{index}].title", use_case["title"]

    privacy = manifest.get("privacy")
    if isinstance(privacy, dict):
        retention = privacy.get("retention")
        if isinstance(retention, dict) and "description" in retention:
            yield "privacy.retention.description", retention["description"]

    actions = manifest.get("actions")
    if isinstance(actions, dict):
        providers = actions.get("providers")
        if isinstance(providers, list):
            for provider_index, provider in enumerate(providers):
                if not isinstance(provider, dict):
                    continue
                for collection_name in ("staticActions", "dynamicTemplates"):
                    entries = provider.get(collection_name)
                    if not isinstance(entries, list):
                        continue
                    for entry_index, entry in enumerate(entries):
                        if not isinstance(entry, dict):
                            continue
                        for field in ("title", "description", "parameterSummary"):
                            if field in entry:
                                yield (
                                    f"actions.providers[{provider_index}].{collection_name}"
                                    f"[{entry_index}].{field}",
                                    entry[field],
                                )

    setup = manifest.get("setup")
    if isinstance(setup, dict):
        steps = setup.get("steps")
        if isinstance(steps, list):
            for index, step in enumerate(steps):
                if not isinstance(step, dict):
                    continue
                for field in ("title", "description"):
                    if field in step:
                        yield f"setup.steps[{index}].{field}", step[field]
        if "missingDependencyHelp" in setup:
            yield "setup.missingDependencyHelp", setup["missingDependencyHelp"]


def validate_runtime_envelope(
    manifest: dict,
    manifest_path: Path,
    *,
    allow_sparse_legacy: bool = False,
) -> str:
    """Validate fields decoded by PluginPackageManifest before projection or packaging."""
    fallback_id = manifest_path.parent.name
    plugin_id = manifest.get("id", fallback_id)
    plugin_kit_version = manifest.get("pluginKitVersion")
    is_sparse_legacy = (
        allow_sparse_legacy
        and type(plugin_kit_version) is int
        and plugin_kit_version < PRODUCT_METADATA_REQUIRED_PLUGIN_KIT_VERSION
    )
    required = {
        "id",
        "displayName",
        "version",
        "minHostVersion",
        "pluginKitVersion",
        "bundleRelativePath",
        "capabilities",
        "permissions",
    }
    if not is_sparse_legacy:
        required.add("category")
    missing = sorted(required - set(manifest))
    if missing:
        _fail(plugin_id, "manifest", "missing required keys: " + ", ".join(missing))

    if "id" in manifest:
        if (
            not isinstance(manifest["id"], str)
            or manifest["id"] == "marketplace"
            or not PLUGIN_IDENTIFIER_PATTERN.fullmatch(manifest["id"])
        ):
            _fail(plugin_id, "id", "must be a valid non-reserved plugin identifier")
        plugin_id = manifest["id"]
    if "displayName" in manifest:
        _non_empty_string(manifest["displayName"], plugin_id, "displayName")
    if "summary" in manifest:
        _non_empty_string(manifest["summary"], plugin_id, "summary")
    for key in ("version", "minHostVersion"):
        if key in manifest:
            _version(manifest[key], plugin_id, key)
    if "pluginKitVersion" in manifest:
        if type(manifest["pluginKitVersion"]) is not int or manifest["pluginKitVersion"] < 1:
            _fail(plugin_id, "pluginKitVersion", "must be a positive integer")
    if "bundleRelativePath" in manifest:
        bundle_path = manifest["bundleRelativePath"]
        if (
            not isinstance(bundle_path, str)
            or not bundle_path
            or bundle_path.startswith("/")
            or ".." in bundle_path.split("/")
        ):
            _fail(plugin_id, "bundleRelativePath", "must be a safe relative path")
    if "factoryClass" in manifest:
        _non_empty_string(manifest["factoryClass"], plugin_id, "factoryClass")
    if "capabilities" in manifest:
        capabilities = manifest["capabilities"]
        if not isinstance(capabilities, dict):
            _fail(plugin_id, "capabilities", "must be an object")
        if is_sparse_legacy:
            allowed_capabilities = {
                "primaryPanel", "componentPanel", "settings", "configuration"
            }
            required_capabilities = set()
        elif plugin_kit_version >= 7:
            allowed_capabilities = {"panelItems", "settings"}
            required_capabilities = allowed_capabilities
        else:
            allowed_capabilities = {"primaryPanel", "componentPanel", "settings"}
            required_capabilities = allowed_capabilities
        missing_capabilities = sorted(required_capabilities - set(capabilities))
        if missing_capabilities:
            _fail(
                plugin_id,
                "capabilities",
                "missing required keys: " + ", ".join(missing_capabilities),
            )
        unexpected_capabilities = sorted(set(capabilities) - allowed_capabilities)
        if unexpected_capabilities:
            _fail(
                plugin_id,
                "capabilities",
                "contains unsupported keys: " + ", ".join(unexpected_capabilities),
            )
        for key in ("primaryPanel", "componentPanel"):
            if key in capabilities and type(capabilities[key]) is not bool:
                _fail(plugin_id, f"capabilities.{key}", "must be a boolean")
        if "panelItems" in capabilities:
            _unique_strings(capabilities["panelItems"], plugin_id, "capabilities.panelItems")
            if set(capabilities["panelItems"]) - {"row", "widget"}:
                _fail(plugin_id, "capabilities.panelItems", "contains an unsupported renderer")
        if "settings" in capabilities:
            settings = capabilities["settings"]
            if not isinstance(settings, str) or settings not in VALID_SETTINGS_CAPABILITIES:
                _fail(plugin_id, "capabilities.settings", "is not supported")
        if "configuration" in capabilities and type(capabilities["configuration"]) is not bool:
            _fail(plugin_id, "capabilities.configuration", "must be a boolean")
    if "permissions" in manifest:
        _unique_strings(manifest["permissions"], plugin_id, "permissions")
        invalid_permissions = sorted(set(manifest["permissions"]) - VALID_PERMISSION_IDS)
        if invalid_permissions:
            _fail(plugin_id, "permissions", "unknown: " + ", ".join(invalid_permissions))
    if "category" in manifest:
        category = manifest["category"]
        if not isinstance(category, str) or category not in VALID_CATEGORIES:
            _fail(plugin_id, "category", "is not a supported category")
    if "releaseChannel" in manifest:
        _non_empty_string(manifest["releaseChannel"], plugin_id, "releaseChannel")
    if "releaseNotesURL" in manifest:
        _https_url(manifest["releaseNotesURL"], plugin_id, "releaseNotesURL")
    if "localizedMetadata" in manifest:
        metadata = manifest["localizedMetadata"]
        if not isinstance(metadata, dict):
            _fail(plugin_id, "localizedMetadata", "must be an object")
        for locale, localized in metadata.items():
            if not isinstance(locale, str) or not locale.strip():
                _fail(plugin_id, "localizedMetadata", "must use non-empty locale keys")
            if not isinstance(localized, dict):
                _fail(plugin_id, f"localizedMetadata.{locale}", "must be an object")
            unexpected = sorted(set(localized) - {"displayName", "summary"})
            if unexpected:
                _fail(
                    plugin_id,
                    f"localizedMetadata.{locale}",
                    "contains unsupported keys: " + ", ".join(unexpected),
                )
            for field in ("displayName", "summary"):
                if field in localized:
                    _non_empty_string(
                        localized[field],
                        plugin_id,
                        f"localizedMetadata.{locale}.{field}",
                    )
    return plugin_id


def _localizable_string(
    reference: str,
    manifest_path: Path | None,
    plugin_id: str,
    field: str,
) -> dict[str, str]:
    if manifest_path is None:
        _fail(plugin_id, field, f"{reference} requires a source manifest path")
    catalog_path = manifest_path.parent / "Resources" / "Localizable.xcstrings"
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        _fail(plugin_id, field, f"cannot read {catalog_path}: {error}")
    key = reference.removeprefix(LOCALIZABLE_STRING_REFERENCE_PREFIX)
    entry = catalog.get("strings", {}).get(key)
    if not isinstance(entry, dict):
        _fail(plugin_id, field, f"references missing Localizable.xcstrings key {key}")
    localizations = entry.get("localizations")
    if not isinstance(localizations, dict):
        _fail(plugin_id, field, f"Localizable.xcstrings key {key} has no localizations")
    localized_value = {}
    for locale in SUPPORTED_LOCALE_ORDER:
        localized = localizations.get(locale)
        string_unit = localized.get("stringUnit") if isinstance(localized, dict) else None
        value = string_unit.get("value") if isinstance(string_unit, dict) else None
        if not isinstance(value, str) or not value.strip():
            _fail(
                plugin_id,
                field,
                f"Localizable.xcstrings key {key} is missing locale {locale}",
            )
        localized_value[locale] = value
    return localized_value


def _standard_setup_string(
    reference: str,
    manifest: dict,
    plugin_id: str,
    field: str,
) -> dict[str, str]:
    template_key = reference.removeprefix(STANDARD_SETUP_REFERENCE_PREFIX)
    templates = STANDARD_SETUP_TEMPLATES.get(template_key)
    if templates is None:
        _fail(plugin_id, field, f"unknown standard setup string {template_key}")

    metadata = manifest.get("localizedMetadata")
    if not isinstance(metadata, dict) or set(metadata) != SUPPORTED_LOCALE_SET:
        _fail(
            plugin_id,
            field,
            f"{reference} requires localizedMetadata for all supported locales",
        )
    requirements = manifest.get("requirements")
    if not isinstance(requirements, dict):
        _fail(plugin_id, field, f"{reference} requires a requirements section")

    requirement_values: list[dict[str, str]] = []
    for permission_id in requirements.get("permissionIDs", []):
        localized = LOCALIZED_REQUIREMENT_NAMES.get(permission_id)
        if localized is None:
            _fail(plugin_id, field, f"cannot localize permission requirement {permission_id}")
        requirement_values.append(localized)
    for hardware in requirements.get("hardware", []):
        localized = LOCALIZED_REQUIREMENT_NAMES.get(hardware)
        if localized is None:
            _fail(plugin_id, field, f"cannot localize hardware requirement {hardware}")
        requirement_values.append(localized)
    for application in requirements.get("applications", []):
        name = application.get("name") if isinstance(application, dict) else None
        if not isinstance(name, str) or not name.strip():
            _fail(plugin_id, field, "cannot localize an unnamed application requirement")
        requirement_values.append({locale: name for locale in SUPPORTED_LOCALE_ORDER})
    for executable in requirements.get("executables", []):
        if not isinstance(executable, str) or not executable.strip():
            _fail(plugin_id, field, "cannot localize an unnamed executable requirement")
        requirement_values.append({locale: executable for locale in SUPPORTED_LOCALE_ORDER})
    if not requirement_values:
        _fail(plugin_id, field, f"{reference} requires at least one declared requirement")

    separators = {"ar": "، ", "ja": "、", "zh-Hans": "、", "zh-Hant": "、"}
    localized_value = {}
    for locale in SUPPORTED_LOCALE_ORDER:
        locale_metadata = metadata.get(locale)
        display_name = locale_metadata.get("displayName") if isinstance(locale_metadata, dict) else None
        if not isinstance(display_name, str) or not display_name.strip():
            _fail(plugin_id, f"localizedMetadata.{locale}.displayName", "must be a non-empty string")
        joined_requirements = separators.get(locale, ", ").join(
            value[locale] for value in requirement_values
        )
        localized_value[locale] = templates[locale].format(
            displayName=display_name,
            requirements=joined_requirements,
        )
    return localized_value


def expand_localized_references(
    manifest: dict,
    manifest_path: Path | None = None,
) -> dict:
    """Expand source-only product-string references for catalog and package projection."""
    projected = json.loads(json.dumps(manifest))
    localized_fields = list(_localized_source_fields(projected))
    product_strings = projected.get("productStrings")
    plugin_id = projected.get("id", "unknown-plugin")

    if not localized_fields:
        if product_strings is not None:
            _fail(plugin_id, "productStrings", "is not allowed without localized product fields")
        return projected
    if not isinstance(product_strings, dict) or not product_strings:
        _fail(plugin_id, "productStrings", "must be a non-empty object")

    metadata = projected.get("localizedMetadata")
    reference_values = {}
    used_product_strings = set()
    for key, value in product_strings.items():
        _identifier(key, plugin_id, f"productStrings.{key}")
        if isinstance(value, str) and value in BASE_LOCALIZED_REFERENCES:
            field = value.removeprefix("@")
            if not isinstance(metadata, dict) or set(metadata) != SUPPORTED_LOCALE_SET:
                _fail(
                    plugin_id,
                    f"productStrings.{key}",
                    f"{value} requires localizedMetadata for all supported locales",
                )
            localized_value = {}
            for locale in SUPPORTED_LOCALE_ORDER:
                locale_metadata = metadata.get(locale)
                if not isinstance(locale_metadata, dict):
                    _fail(plugin_id, f"localizedMetadata.{locale}", "must be an object")
                text = locale_metadata.get(field)
                if not isinstance(text, str) or not text.strip():
                    _fail(
                        plugin_id,
                        f"localizedMetadata.{locale}.{field}",
                        "must be a non-empty string",
                    )
                localized_value[locale] = text
            reference_values[key] = localized_value
        elif isinstance(value, str) and value.startswith(LOCALIZABLE_STRING_REFERENCE_PREFIX):
            reference_values[key] = _localizable_string(
                value,
                manifest_path,
                plugin_id,
                f"productStrings.{key}",
            )
        elif isinstance(value, str) and value.startswith(STANDARD_ACTION_REFERENCE_PREFIX):
            template_key = value.removeprefix(STANDARD_ACTION_REFERENCE_PREFIX)
            templates = STANDARD_ACTION_TEMPLATES.get(template_key)
            if templates is None:
                _fail(plugin_id, f"productStrings.{key}", f"unknown standard action string {template_key}")
            if not isinstance(metadata, dict) or set(metadata) != SUPPORTED_LOCALE_SET:
                _fail(
                    plugin_id,
                    f"productStrings.{key}",
                    f"{value} requires localizedMetadata for all supported locales",
                )
            localized_value = {}
            for locale in SUPPORTED_LOCALE_ORDER:
                locale_metadata = metadata.get(locale)
                if not isinstance(locale_metadata, dict):
                    _fail(plugin_id, f"localizedMetadata.{locale}", "must be an object")
                display_name = locale_metadata.get("displayName")
                if not isinstance(display_name, str) or not display_name.strip():
                    _fail(
                        plugin_id,
                        f"localizedMetadata.{locale}.displayName",
                        "must be a non-empty string",
                    )
                localized_value[locale] = templates[locale].format(displayName=display_name)
            reference_values[key] = localized_value
        elif isinstance(value, str) and value.startswith(STANDARD_SETUP_REFERENCE_PREFIX):
            reference_values[key] = _standard_setup_string(
                value,
                projected,
                plugin_id,
                f"productStrings.{key}",
            )
        elif isinstance(value, dict):
            _localized_text(value, plugin_id, f"productStrings.{key}")
            reference_values[key] = dict(value)
        else:
            _fail(
                plugin_id,
                f"productStrings.{key}",
                "must be @displayName, @summary, @localizable.<key>, @standardAction.<key>, "
                "@standardSetup.<key>, or a complete locale-to-string object",
            )

    for field, value in localized_fields:
        if not isinstance(value, str) or not value.startswith(PRODUCT_STRING_REFERENCE_PREFIX):
            _fail(
                plugin_id,
                field,
                f"must reference {PRODUCT_STRING_REFERENCE_PREFIX}<key>; inline localized text is not allowed",
            )
        key = value.removeprefix(PRODUCT_STRING_REFERENCE_PREFIX)
        if key not in reference_values:
            _fail(plugin_id, field, f"references missing productStrings entry {key}")
        used_product_strings.add(key)

    unused_product_strings = sorted(set(reference_values) - used_product_strings)
    if unused_product_strings:
        _fail(
            plugin_id,
            "productStrings",
            "contains unused entries: " + ", ".join(unused_product_strings),
        )

    def expand(value: object) -> object:
        if isinstance(value, str) and value.startswith(PRODUCT_STRING_REFERENCE_PREFIX):
            key = value.removeprefix(PRODUCT_STRING_REFERENCE_PREFIX)
            return dict(reference_values[key])
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value

    for section in (
        "presentation", "discovery", "requirements", "privacy", "actions", "setup", "relationships"
    ):
        if section in projected:
            projected[section] = expand(projected[section])
    projected.pop("productStrings", None)
    return projected


def _fail(plugin_id: str, field: str, message: str) -> None:
    raise ManifestValidationError(f"{plugin_id}: {field}: {message}")


def _require_keys(value: dict, keys: set[str], plugin_id: str, field: str) -> None:
    if not isinstance(value, dict):
        _fail(plugin_id, field, "must be an object")
    missing = sorted(keys - value.keys())
    if missing:
        _fail(plugin_id, field, "missing " + ", ".join(missing))


def _unique_strings(values: list, plugin_id: str, field: str) -> None:
    if not isinstance(values, list):
        _fail(plugin_id, field, "must be an array")
    if not all(isinstance(value, str) and value.strip() for value in values):
        _fail(plugin_id, field, "must contain non-empty strings")
    if len(values) != len(set(values)):
        _fail(plugin_id, field, "contains duplicate values")


def _non_empty_string(value: object, plugin_id: str, field: str) -> None:
    if not isinstance(value, str) or not value.strip():
        _fail(plugin_id, field, "must be a non-empty string")


def _localized_text(value: object, plugin_id: str, field: str, require_all: bool = True) -> None:
    if not isinstance(value, dict) or not value:
        _fail(plugin_id, field, "must be a locale-to-string object")
    unknown = sorted(set(value) - SUPPORTED_LOCALE_SET)
    if unknown:
        _fail(plugin_id, field, "uses unsupported locales: " + ", ".join(unknown))
    if require_all:
        missing = sorted(SUPPORTED_LOCALE_SET - set(value))
        if missing:
            _fail(plugin_id, field, "missing locale fallback values: " + ", ".join(missing))
    if not all(isinstance(text, str) and text.strip() for text in value.values()):
        _fail(plugin_id, field, "contains an empty localized value")


def _identifier(value: object, plugin_id: str, field: str) -> None:
    if not isinstance(value, str) or not IDENTIFIER_PATTERN.fullmatch(value):
        _fail(plugin_id, field, "must be a stable identifier")


def _version(value: object, plugin_id: str, field: str) -> None:
    if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
        _fail(plugin_id, field, "must contain one to three numeric version components")


def _https_url(value: object, plugin_id: str, field: str) -> None:
    if not isinstance(value, str) or any(character.isspace() for character in value):
        _fail(plugin_id, field, "must be an HTTPS URL")
    try:
        parsed = urlparse(value)
        hostname = parsed.hostname
        parsed.port
    except ValueError:
        _fail(plugin_id, field, "must be an HTTPS URL")
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        _fail(plugin_id, field, "must be an HTTPS URL")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        if not DOMAIN_PATTERN.fullmatch(hostname):
            _fail(plugin_id, field, "must be an HTTPS URL")


def validate_https_url(value: object, owner: str, field: str) -> None:
    _https_url(value, owner, field)


def _image_dimensions(path: Path, media_type: str) -> tuple[int | None, int | None]:
    data = path.read_bytes()
    if media_type == "image/png" and len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if media_type == "image/jpeg":
        index = 2
        while index + 9 < len(data):
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            index += 2
            if marker in {0xD8, 0xD9}:
                continue
            if index + 2 > len(data):
                break
            length = int.from_bytes(data[index:index + 2], "big")
            if marker in {
                0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
            }:
                if index + 7 <= len(data):
                    return (
                        int.from_bytes(data[index + 5:index + 7], "big"),
                        int.from_bytes(data[index + 3:index + 5], "big"),
                    )
                break
            index += max(length, 2)
    if media_type == "image/webp" and len(data) >= 20 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        index = 12
        while index + 8 <= len(data):
            chunk_type = data[index:index + 4]
            chunk_size = int.from_bytes(data[index + 4:index + 8], "little")
            payload = data[index + 8:index + 8 + chunk_size]
            if len(payload) != chunk_size:
                break
            if chunk_type == b"VP8X" and len(payload) >= 10:
                return (
                    1 + int.from_bytes(payload[4:7], "little"),
                    1 + int.from_bytes(payload[7:10], "little"),
                )
            if chunk_type == b"VP8L" and len(payload) >= 5 and payload[0] == 0x2F:
                width = 1 + payload[1] + ((payload[2] & 0x3F) << 8)
                height = 1 + (payload[2] >> 6) + (payload[3] << 2) + ((payload[4] & 0x0F) << 10)
                return width, height
            if chunk_type == b"VP8 " and len(payload) >= 10 and payload[3:6] == b"\x9d\x01\x2a":
                return (
                    int.from_bytes(payload[6:8], "little") & 0x3FFF,
                    int.from_bytes(payload[8:10], "little") & 0x3FFF,
                )
            index += 8 + chunk_size + (chunk_size % 2)
    return None, None


def _image_media_type(path: Path) -> str | None:
    header = path.read_bytes()[:16]
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if header.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if len(header) >= 12 and header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return "image/webp"
    return None


def _validate_asset(asset: dict, plugin_root: Path, plugin_id: str, field: str) -> AssetProjection:
    _require_keys(asset, {"id", "path", "alt"}, plugin_id, field)
    _identifier(asset["id"], plugin_id, f"{field}.id")
    _localized_text(asset["alt"], plugin_id, f"{field}.alt")
    _non_empty_string(asset["path"], plugin_id, f"{field}.path")
    relative = PurePosixPath(asset["path"])
    if relative.is_absolute() or ".." in relative.parts or relative.parts[:1] != ("MarketplaceAssets",):
        _fail(plugin_id, f"{field}.path", "must stay under MarketplaceAssets/")
    resolved_plugin_root = plugin_root.resolve()
    asset_root = plugin_root.joinpath("MarketplaceAssets").resolve()
    try:
        asset_root.relative_to(resolved_plugin_root)
    except ValueError:
        _fail(plugin_id, f"{field}.path", "MarketplaceAssets must stay inside the plugin directory")
    source = plugin_root.joinpath(*relative.parts)
    if not source.is_file():
        _fail(plugin_id, f"{field}.path", f"asset does not exist: {relative}")
    try:
        resolved_source = source.resolve(strict=True)
        resolved_source.relative_to(asset_root)
    except ValueError:
        _fail(plugin_id, f"{field}.path", "must resolve inside MarketplaceAssets/")
    source = resolved_source
    size = source.stat().st_size
    if size <= 0 or size > MAX_ASSET_BYTES:
        _fail(plugin_id, f"{field}.path", f"asset size must be 1...{MAX_ASSET_BYTES} bytes")
    media_type = _image_media_type(source)
    if media_type is None:
        _fail(plugin_id, f"{field}.path", "must be PNG, JPEG, or WebP")
    width, height = _image_dimensions(source, media_type)
    if width is None or height is None:
        _fail(plugin_id, f"{field}.path", "image dimensions could not be parsed")
    if width <= 0 or height <= 0 or width > MAX_ASSET_DIMENSION or height > MAX_ASSET_DIMENSION:
        _fail(plugin_id, f"{field}.path", f"dimensions must not exceed {MAX_ASSET_DIMENSION}px")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    projected = dict(asset)
    projected.update({"mediaType": media_type, "sha256": digest, "size": size})
    projected.update({"width": width, "height": height})
    return AssetProjection(source=source, catalog=projected)


def _validate_projected_asset(asset: dict, plugin_id: str, field: str) -> dict:
    _require_keys(asset, {"id", "path", "alt"}, plugin_id, field)
    _identifier(asset["id"], plugin_id, f"{field}.id")
    _localized_text(asset["alt"], plugin_id, f"{field}.alt")
    _non_empty_string(asset["path"], plugin_id, f"{field}.path")
    relative = PurePosixPath(asset["path"])
    if relative.is_absolute() or ".." in relative.parts or relative.parts[:1] != ("MarketplaceAssets",):
        _fail(plugin_id, f"{field}.path", "must stay under MarketplaceAssets/")
    return json.loads(json.dumps(asset))


def _validate_parameters(parameters: object, plugin_id: str, field: str) -> None:
    if not isinstance(parameters, list):
        _fail(plugin_id, field, "must be an array")
    seen: set[str] = set()
    for index, parameter in enumerate(parameters):
        item_field = f"{field}[{index}]"
        if not isinstance(parameter, dict):
            _fail(plugin_id, item_field, "must be an object")
        _require_keys(parameter, {"id", "kind", "isRequired", "portability"}, plugin_id, item_field)
        _identifier(parameter["id"], plugin_id, f"{item_field}.id")
        if parameter["id"] in seen:
            _fail(plugin_id, f"{item_field}.id", "duplicates a parameter ID")
        seen.add(parameter["id"])
        if parameter["kind"] not in VALID_PARAMETER_KINDS:
            _fail(plugin_id, f"{item_field}.kind", "is not supported")
        if parameter["portability"] not in VALID_PORTABILITY:
            _fail(plugin_id, f"{item_field}.portability", "is not supported")
        if not isinstance(parameter["isRequired"], bool):
            _fail(plugin_id, f"{item_field}.isRequired", "must be a boolean")


def _validate_action_policy(
    action: dict,
    plugin_id: str,
    field: str,
    risk_varies_by_entry: bool = False,
    automatic_eligibility_varies_by_entry: bool = False,
) -> None:
    for key in ("permissionIDs", "surfaces", "keywords"):
        _unique_strings(action[key], plugin_id, f"{field}.{key}")
    invalid_permissions = sorted(set(action["permissionIDs"]) - VALID_PERMISSION_IDS)
    if invalid_permissions:
        _fail(plugin_id, f"{field}.permissionIDs", "unknown: " + ", ".join(invalid_permissions))
    invalid_surfaces = sorted(set(action["surfaces"]) - VALID_SURFACES)
    if invalid_surfaces:
        _fail(plugin_id, f"{field}.surfaces", "unknown: " + ", ".join(invalid_surfaces))
    if action["risk"] not in VALID_RISKS:
        _fail(plugin_id, f"{field}.risk", "is not supported")
    if action["externalInvocation"] not in VALID_EXTERNAL_POLICIES:
        _fail(plugin_id, f"{field}.externalInvocation", "is not supported")
    if not isinstance(action["automaticEligible"], bool):
        _fail(plugin_id, f"{field}.automaticEligible", "must be a boolean")
    can_be_safe = action["risk"] == "safe" or risk_varies_by_entry
    can_be_automatic = (
        action["automaticEligible"] or automatic_eligibility_varies_by_entry
    )
    if "automatic-rule" in action["surfaces"] and not (
        can_be_safe and can_be_automatic
    ):
        _fail(plugin_id, field, "automatic-rule requires a potentially safe automatic action")
    if "app-intent" in action["surfaces"] and (
        not can_be_safe
        or not can_be_automatic
        or any(parameter["portability"] != "portable" for parameter in action["parameters"])
        or action.get("localOnlyIdentity") is True
    ):
        _fail(plugin_id, field, "app-intent requires a potentially safe, automatic, portable action")
    has_run_link = "run-link" in action["surfaces"]
    supports_run_link = action["externalInvocation"] != "unavailable"
    if has_run_link != supports_run_link:
        _fail(plugin_id, field, "run-link must match the external invocation policy")


def _validate_actions(actions: dict, plugin_id: str) -> None:
    _require_keys(actions, {"providers"}, plugin_id, "actions")
    if not isinstance(actions["providers"], list) or not actions["providers"]:
        _fail(plugin_id, "actions.providers", "must be a non-empty array")
    seen_keys: set[tuple[str, str]] = set()
    seen_providers: set[str] = set()
    for provider_index, provider in enumerate(actions["providers"]):
        field = f"actions.providers[{provider_index}]"
        _require_keys(provider, {"id", "kind", "staticActions", "dynamicTemplates"}, plugin_id, field)
        _identifier(provider["id"], plugin_id, f"{field}.id")
        if provider["id"] in seen_providers:
            _fail(plugin_id, f"{field}.id", "duplicates a provider ID")
        seen_providers.add(provider["id"])
        if provider["kind"] not in VALID_PROVIDER_KINDS:
            _fail(plugin_id, f"{field}.kind", "is not supported")
        static_actions = provider["staticActions"]
        dynamic_templates = provider["dynamicTemplates"]
        if not isinstance(static_actions, list) or not isinstance(dynamic_templates, list):
            _fail(plugin_id, field, "action collections must be arrays")
        if provider["kind"] == "static" and (not static_actions or dynamic_templates):
            _fail(plugin_id, field, "static providers require only staticActions")
        if provider["kind"] == "dynamic" and (static_actions or not dynamic_templates):
            _fail(plugin_id, field, "dynamic providers require only dynamicTemplates")
        if provider["kind"] == "mixed" and (not static_actions or not dynamic_templates):
            _fail(plugin_id, field, "mixed providers require both action kinds")
        for index, action in enumerate(static_actions):
            action_field = f"{field}.staticActions[{index}]"
            _require_keys(action, {
                "id", "title", "description", "keywords", "systemImage", "parameters",
                "permissionIDs", "risk", "surfaces", "automaticEligible", "externalInvocation"
            }, plugin_id, action_field)
            _identifier(action["id"], plugin_id, f"{action_field}.id")
            key = (provider["id"], action["id"])
            if key in seen_keys:
                _fail(plugin_id, f"{action_field}.id", "duplicates a static action key")
            seen_keys.add(key)
            _localized_text(action["title"], plugin_id, f"{action_field}.title")
            _localized_text(action["description"], plugin_id, f"{action_field}.description")
            _non_empty_string(action["systemImage"], plugin_id, f"{action_field}.systemImage")
            if "parameterSummary" in action:
                _localized_text(action["parameterSummary"], plugin_id, f"{action_field}.parameterSummary")
            _validate_parameters(action["parameters"], plugin_id, f"{action_field}.parameters")
            if not action["parameters"] and "parameterSummary" in action:
                _fail(
                    plugin_id,
                    f"{action_field}.parameterSummary",
                    "is not allowed for an action without parameters",
                )
            _validate_action_policy(action, plugin_id, action_field)
        for index, template in enumerate(dynamic_templates):
            template_field = f"{field}.dynamicTemplates[{index}]"
            _require_keys(template, {
                "id", "title", "description", "entrySource", "parameters", "parameterSummary",
                "localOnlyIdentity", "permissionIDs", "risk", "surfaces", "automaticEligible",
                "externalInvocation", "keywords"
            }, plugin_id, template_field)
            _identifier(template["id"], plugin_id, f"{template_field}.id")
            key = (provider["id"], template["id"])
            if key in seen_keys:
                _fail(plugin_id, f"{template_field}.id", "duplicates an action or template key")
            seen_keys.add(key)
            _localized_text(template["title"], plugin_id, f"{template_field}.title")
            _localized_text(template["description"], plugin_id, f"{template_field}.description")
            _localized_text(template["parameterSummary"], plugin_id, f"{template_field}.parameterSummary")
            duplicate_summary_locales = [
                locale
                for locale in SUPPORTED_LOCALE_ORDER
                if template["parameterSummary"][locale]
                in {template["title"][locale], template["description"][locale]}
            ]
            if duplicate_summary_locales:
                _fail(
                    plugin_id,
                    f"{template_field}.parameterSummary",
                    "must describe the template parameters instead of repeating the title or "
                    "description; repeated locales: " + ", ".join(duplicate_summary_locales),
                )
            _non_empty_string(template["entrySource"], plugin_id, f"{template_field}.entrySource")
            if not isinstance(template["localOnlyIdentity"], bool):
                _fail(plugin_id, f"{template_field}.localOnlyIdentity", "must be a boolean")
            risk_varies_by_entry = template.get("riskVariesByEntry", False)
            if not isinstance(risk_varies_by_entry, bool):
                _fail(plugin_id, f"{template_field}.riskVariesByEntry", "must be a boolean")
            automatic_eligibility_varies_by_entry = template.get(
                "automaticEligibilityVariesByEntry",
                False,
            )
            if not isinstance(automatic_eligibility_varies_by_entry, bool):
                _fail(
                    plugin_id,
                    f"{template_field}.automaticEligibilityVariesByEntry",
                    "must be a boolean",
                )
            _validate_parameters(template["parameters"], plugin_id, f"{template_field}.parameters")
            _validate_action_policy(
                template,
                plugin_id,
                template_field,
                risk_varies_by_entry=risk_varies_by_entry,
                automatic_eligibility_varies_by_entry=(
                    automatic_eligibility_varies_by_entry
                ),
            )


def _validate_manifest(
    manifest: dict,
    manifest_path: Path,
    known_plugin_ids: set[str],
    *,
    allow_sparse_legacy: bool = False,
    projected_assets: bool = False,
    validate_plugin_references: bool = True,
) -> tuple[dict, list[AssetProjection]]:
    manifest = json.loads(json.dumps(manifest))
    plugin_id = validate_runtime_envelope(
        manifest,
        manifest_path,
        allow_sparse_legacy=allow_sparse_legacy,
    )
    for section in ("presentation", "discovery", "requirements", "privacy", "actions", "setup", "relationships"):
        if section in manifest and not isinstance(manifest[section], dict):
            _fail(plugin_id, section, "must be an object")
    assets: list[AssetProjection] = []
    presentation = manifest.get("presentation")
    if presentation is not None:
        _require_keys(presentation, {
            "longDescription", "examples", "screenshots", "publisher", "license"
        }, plugin_id, "presentation")
        _localized_text(presentation["longDescription"], plugin_id, "presentation.longDescription")
        for key in ("publisher", "license"):
            _non_empty_string(presentation[key], plugin_id, f"presentation.{key}")
        if not isinstance(presentation["examples"], list) or not isinstance(presentation["screenshots"], list):
            _fail(plugin_id, "presentation", "examples and screenshots must be arrays")
        if not all(isinstance(example, dict) for example in presentation["examples"]):
            _fail(plugin_id, "presentation.examples", "must contain objects")
        example_ids = [example.get("id", "") for example in presentation["examples"]]
        _unique_strings(example_ids, plugin_id, "presentation.examples.id")
        for index, example in enumerate(presentation["examples"]):
            _identifier(example.get("id"), plugin_id, f"presentation.examples[{index}].id")
            _localized_text(example.get("text"), plugin_id, f"presentation.examples[{index}].text")
        seen_asset_ids: set[str] = set()
        for index, asset in enumerate(presentation["screenshots"]):
            asset_field = f"presentation.screenshots[{index}]"
            if projected_assets:
                projected_asset = _validate_projected_asset(asset, plugin_id, asset_field)
            else:
                source_asset = _validate_asset(asset, manifest_path.parent, plugin_id, asset_field)
                assets.append(source_asset)
                projected_asset = source_asset.catalog
            if projected_asset["id"] in seen_asset_ids:
                _fail(plugin_id, f"presentation.screenshots[{index}].id", "duplicates an asset ID")
            seen_asset_ids.add(projected_asset["id"])
        for key in ("documentationURL", "supportURL"):
            if key in presentation:
                _https_url(presentation[key], plugin_id, f"presentation.{key}")

    discovery = manifest.get("discovery")
    if discovery is not None:
        _require_keys(discovery, {
            "keywords", "localizedSynonyms", "useCases", "goalCategories",
            "relatedPluginIDs", "alternativePluginIDs"
        }, plugin_id, "discovery")
        _unique_strings(discovery["keywords"], plugin_id, "discovery.keywords")
        if not isinstance(discovery["localizedSynonyms"], dict):
            _fail(plugin_id, "discovery.localizedSynonyms", "must be an object")
        missing_locales = sorted(SUPPORTED_LOCALE_SET - set(discovery["localizedSynonyms"]))
        if missing_locales:
            _fail(plugin_id, "discovery.localizedSynonyms", "missing: " + ", ".join(missing_locales))
        for locale, synonyms in discovery["localizedSynonyms"].items():
            if locale not in SUPPORTED_LOCALE_SET:
                _fail(plugin_id, "discovery.localizedSynonyms", f"unsupported locale {locale}")
            _unique_strings(synonyms, plugin_id, f"discovery.localizedSynonyms.{locale}")
        use_case_ids: list[str] = []
        if not isinstance(discovery["useCases"], list):
            _fail(plugin_id, "discovery.useCases", "must be an array")
        for index, use_case in enumerate(discovery["useCases"]):
            _require_keys(use_case, {"id", "title"}, plugin_id, f"discovery.useCases[{index}]")
            _identifier(use_case["id"], plugin_id, f"discovery.useCases[{index}].id")
            use_case_ids.append(use_case["id"])
            _localized_text(use_case["title"], plugin_id, f"discovery.useCases[{index}].title")
        _unique_strings(use_case_ids, plugin_id, "discovery.useCases.id")
        for key in ("goalCategories", "relatedPluginIDs", "alternativePluginIDs"):
            _unique_strings(discovery[key], plugin_id, f"discovery.{key}")

    requirements = manifest.get("requirements")
    if requirements is not None:
        _require_keys(requirements, {
            "architectures", "hardware", "applications", "executables", "permissionIDs",
            "setupComplexity", "requiresRelaunch"
        }, plugin_id, "requirements")
        for key in ("architectures", "hardware", "executables", "permissionIDs"):
            _unique_strings(requirements[key], plugin_id, f"requirements.{key}")
        invalid_architectures = sorted(set(requirements["architectures"]) - VALID_ARCHITECTURES)
        if invalid_architectures:
            _fail(plugin_id, "requirements.architectures", "unknown: " + ", ".join(invalid_architectures))
        invalid_permissions = sorted(set(requirements["permissionIDs"]) - VALID_PERMISSION_IDS)
        if invalid_permissions:
            _fail(plugin_id, "requirements.permissionIDs", "unknown: " + ", ".join(invalid_permissions))
        if requirements["setupComplexity"] not in VALID_SETUP_COMPLEXITIES:
            _fail(plugin_id, "requirements.setupComplexity", "is not supported")
        if not isinstance(requirements["requiresRelaunch"], bool):
            _fail(plugin_id, "requirements.requiresRelaunch", "must be a boolean")
        if "minimumMacOSVersion" in requirements:
            _version(
                requirements["minimumMacOSVersion"],
                plugin_id,
                "requirements.minimumMacOSVersion",
            )
        applications = requirements["applications"]
        if not isinstance(applications, list):
            _fail(plugin_id, "requirements.applications", "must be an array")
        application_ids = []
        for index, application in enumerate(applications):
            field = f"requirements.applications[{index}]"
            _require_keys(application, {"bundleID", "name"}, plugin_id, field)
            for key in ("bundleID", "name"):
                _non_empty_string(application[key], plugin_id, f"{field}.{key}")
            application_ids.append(application["bundleID"])
        if len(application_ids) != len(set(application_ids)):
            _fail(plugin_id, "requirements.applications", "contains duplicate bundle IDs")

    privacy = manifest.get("privacy")
    if privacy is not None:
        _require_keys(privacy, {
            "dataObserved", "dataPersisted", "retention", "networkUse", "networkDomains",
            "telemetry", "processesSensitiveUserContent", "diagnosticExportsContainUserData"
        }, plugin_id, "privacy")
        for key in ("dataObserved", "dataPersisted", "networkDomains"):
            _unique_strings(privacy[key], plugin_id, f"privacy.{key}")
        if privacy["networkUse"] not in VALID_NETWORK_USE:
            _fail(plugin_id, "privacy.networkUse", "is not supported")
        if privacy["telemetry"] not in VALID_TELEMETRY:
            _fail(plugin_id, "privacy.telemetry", "is not supported")
        for domain in privacy["networkDomains"]:
            if not isinstance(domain, str) or not DOMAIN_PATTERN.fullmatch(domain):
                _fail(plugin_id, "privacy.networkDomains", f"invalid domain: {domain}")
        if "allowsUserConfiguredDomains" in privacy and not isinstance(
            privacy["allowsUserConfiguredDomains"], bool
        ):
            _fail(plugin_id, "privacy.allowsUserConfiguredDomains", "must be a boolean")
        for key in ("processesSensitiveUserContent", "diagnosticExportsContainUserData"):
            if not isinstance(privacy[key], bool):
                _fail(plugin_id, f"privacy.{key}", "must be a boolean")
        retention = privacy["retention"]
        if not isinstance(retention, dict) or retention.get("policy") not in VALID_RETENTION:
            _fail(plugin_id, "privacy.retention.policy", "is not supported")
        if retention.get("description") is not None:
            _localized_text(retention["description"], plugin_id, "privacy.retention.description")

    if manifest.get("actions") is not None:
        _validate_actions(manifest["actions"], plugin_id)
        declared_permissions = set(manifest.get("permissions", []))
        requirement_permissions = set(
            manifest.get("requirements", {}).get("permissionIDs", [])
        )
        for provider_index, provider in enumerate(manifest["actions"]["providers"]):
            for collection_name in ("staticActions", "dynamicTemplates"):
                for action_index, action in enumerate(provider[collection_name]):
                    field = (
                        f"actions.providers[{provider_index}].{collection_name}"
                        f"[{action_index}].permissionIDs"
                    )
                    action_permissions = set(action["permissionIDs"])
                    missing_top_level = sorted(action_permissions - declared_permissions)
                    if missing_top_level:
                        _fail(
                            plugin_id,
                            field,
                            "must also appear in top-level permissions: "
                            + ", ".join(missing_top_level),
                        )
                    missing_requirements = sorted(action_permissions - requirement_permissions)
                    if missing_requirements:
                        _fail(
                            plugin_id,
                            field,
                            "must also appear in requirements.permissionIDs: "
                            + ", ".join(missing_requirements),
                        )

    setup = manifest.get("setup")
    if setup is not None:
        _require_keys(setup, {"steps", "optionalSurfaces"}, plugin_id, "setup")
        if not isinstance(setup["steps"], list):
            _fail(plugin_id, "setup.steps", "must be an array")
        if (
            requirements is not None
            and requirements["setupComplexity"] in {"guided", "advanced"}
            and not setup["steps"]
        ):
            _fail(plugin_id, "setup.steps", "guided and advanced setup requires at least one step")
        for index, step in enumerate(setup["steps"]):
            _require_keys(step, {"id", "title", "description"}, plugin_id, f"setup.steps[{index}]")
            _identifier(step["id"], plugin_id, f"setup.steps[{index}].id")
            _localized_text(step["title"], plugin_id, f"setup.steps[{index}].title")
            _localized_text(step["description"], plugin_id, f"setup.steps[{index}].description")
            localized_metadata = manifest.get("localizedMetadata", {})
            if all(
                step["title"].get(locale) == localized_metadata.get(locale, {}).get("displayName")
                and step["description"].get(locale) == localized_metadata.get(locale, {}).get("summary")
                for locale in SUPPORTED_LOCALE_ORDER
            ):
                _fail(
                    plugin_id,
                    f"setup.steps[{index}]",
                    "must describe concrete setup requirements instead of repeating product metadata",
                )
        test_action = setup.get("suggestedTestAction")
        if test_action is not None:
            _require_keys(test_action, {"providerID", "actionID"}, plugin_id, "setup.suggestedTestAction")
            _identifier(test_action["providerID"], plugin_id, "setup.suggestedTestAction.providerID")
            _identifier(test_action["actionID"], plugin_id, "setup.suggestedTestAction.actionID")
            key = (test_action.get("providerID"), test_action.get("actionID"))
            static_keys = {
                (provider["id"], action["id"])
                for provider in manifest.get("actions", {}).get("providers", [])
                for action in provider.get("staticActions", [])
            }
            if key not in static_keys:
                _fail(plugin_id, "setup.suggestedTestAction", "must reference a declared static action")
        _unique_strings(setup["optionalSurfaces"], plugin_id, "setup.optionalSurfaces")
        invalid_surfaces = sorted(set(setup["optionalSurfaces"]) - VALID_SURFACES)
        if invalid_surfaces:
            _fail(plugin_id, "setup.optionalSurfaces", "unknown: " + ", ".join(invalid_surfaces))
        if setup.get("missingDependencyHelp") is not None:
            _localized_text(setup["missingDependencyHelp"], plugin_id, "setup.missingDependencyHelp")

    relationships = manifest.get("relationships")
    if relationships is not None:
        _require_keys(relationships, {
            "relatedPluginIDs", "includedPackIDs", "suggestedRecipeIDs", "supersedesPluginIDs"
        }, plugin_id, "relationships")
        for key in ("relatedPluginIDs", "includedPackIDs", "suggestedRecipeIDs", "supersedesPluginIDs"):
            _unique_strings(relationships[key], plugin_id, f"relationships.{key}")
        referenced = set(relationships["relatedPluginIDs"]) | set(relationships["supersedesPluginIDs"])
        if validate_plugin_references:
            missing = sorted(referenced - known_plugin_ids)
            if missing:
                _fail(plugin_id, "relationships", "references unknown plugins: " + ", ".join(missing))

    if discovery is not None:
        referenced = set(discovery["relatedPluginIDs"]) | set(discovery["alternativePluginIDs"])
        if validate_plugin_references:
            missing = sorted(referenced - known_plugin_ids)
            if missing:
                _fail(plugin_id, "discovery", "references unknown plugins: " + ", ".join(missing))

    projected = json.loads(json.dumps(manifest))
    if presentation is not None:
        if projected_assets:
            projected["presentation"]["screenshots"] = [
                _validate_projected_asset(
                    asset,
                    plugin_id,
                    f"presentation.screenshots[{index}]",
                )
                for index, asset in enumerate(presentation["screenshots"])
            ]
        else:
            projected["presentation"]["screenshots"] = [asset.catalog for asset in assets]
    projected.pop("build", None)
    projected.pop("package", None)
    return projected, assets


def validate_and_project_manifest(
    manifest: dict,
    manifest_path: Path,
    known_plugin_ids: set[str],
    *,
    allow_sparse_legacy: bool = False,
) -> tuple[dict, list[AssetProjection]]:
    return _validate_manifest(
        expand_localized_references(manifest, manifest_path),
        manifest_path,
        known_plugin_ids,
        allow_sparse_legacy=allow_sparse_legacy,
    )


def validate_projected_manifest(
    manifest: dict,
    manifest_path: Path,
    known_plugin_ids: set[str],
    *,
    allow_sparse_legacy: bool = False,
    validate_plugin_references: bool = True,
) -> dict:
    if "productStrings" in manifest:
        _fail(
            manifest.get("id", manifest_path.parent.name),
            "productStrings",
            "must be removed from a projected package manifest",
        )
    projected, _ = _validate_manifest(
        manifest,
        manifest_path,
        known_plugin_ids,
        allow_sparse_legacy=allow_sparse_legacy,
        projected_assets=True,
        validate_plugin_references=validate_plugin_references,
    )
    return projected


def load_known_plugin_ids(plugins_root: Path) -> set[str]:
    if (plugins_root / "plugin.json").is_file():
        return {
            json.loads((plugins_root / "plugin.json").read_text(encoding="utf-8"))["id"]
        }
    result = set()
    for path in plugins_root.glob("*/plugin.json"):
        plugin_id = json.loads(path.read_text(encoding="utf-8"))["id"]
        if plugin_id in result:
            raise ManifestValidationError(
                f"{plugin_id}: id: duplicates another plugin manifest under {plugins_root}"
            )
        result.add(plugin_id)
    return result
