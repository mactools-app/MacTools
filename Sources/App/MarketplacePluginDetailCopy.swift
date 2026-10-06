import Foundation

/// Presents catalog vocabulary without changing the signed machine-readable metadata.
enum MarketplacePluginDetailCopy {
    static func value(_ value: String, group: String) -> String {
        AppL10n.plugins("plugin.marketplace.\(group).\(value)", defaultValue: value)
    }

    static func label(_ value: String) -> String {
        guard let fallback = labels[value] else { return value }
        return AppL10n.plugins("plugin.marketplace.label.\(value)", defaultValue: fallback)
    }

    static func list(_ values: [String], labels: Bool = false, group: String? = nil) -> String {
        FeatureL10n.joined(values.map { item in
            if labels { return label(item) }
            if let group { return value(item, group: group) }
            return item
        })
    }

    private static let labels: [String: String] = [
        "system-state": "系统状态",
        "productivity-state": "效率工具设置",
        "clipboard-content": "剪贴板内容",
        "frontmost-application": "前台应用",
        "local-keyword-input-when-enabled": "启用时的关键词输入",
        "foreground-application": "前台应用",
        "input-source": "输入源",
        "screen-pixels": "屏幕像素",
        "window-geometry": "窗口位置与大小",
        "recognized-text-and-codes": "识别出的文本、二维码和条形码",
        "input-events": "输入事件",
        "calendar-events": "日历事件",
        "selected-files": "所选文件",
        "window-titles": "窗口标题",
        "window-frames": "窗口位置与大小",
        "connected-device-battery-state": "已连接设备的电量",
        "display-state": "显示器状态",
        "system-appearance": "系统外观",
        "filesystem-paths": "文件路径",
        "file-sizes": "文件大小",
        "active-audio-applications": "正在播放音频的应用",
        "application-audio-levels": "应用音量",
        "running-applications": "运行中的应用",
        "application-windows": "应用窗口",
        "audio-state": "音频状态",
        "shortcut-names": "快捷指令名称",
        "shortcut-folders": "快捷指令文件夹",
        "menu-bar-items": "菜单栏项目",
        "menu-bar-icon-images": "菜单栏图标",
        "pointer-events": "指针事件",
        "installed-applications": "已安装应用",
        "upload-configuration": "上传配置",
        "selected-text": "所选文本",
        "screenshots": "截屏",
        "translation-requests": "翻译请求",
        "monitoring-state": "监控状态",
        "script-content": "脚本内容",
        "script-output": "脚本输出",
        "script-working-directories": "脚本工作目录",
        "developer-cache-paths": "开发缓存路径",
        "storage-state": "存储状态",
        "subscription-quota": "订阅额度",
        "local-cli-credentials": "本机 CLI 凭据",
        "system-settings": "系统设置",
        "input-device-availability": "输入设备可用状态",
        "siri-message-input": "Siri 消息输入",
        "siri-submission-state": "Siri 发送状态",
        "ai-requests": "AI 请求",
        "usage-statistics": "用量统计",
        "ai-prompt-content": "AI 提示词内容",
        "project-working-directories": "项目工作目录",
        "local-network-addresses": "内网地址",
        "public-network-addresses": "公网地址",
        "network-location": "IP 地理位置",
        "connectivity-results": "连通性结果",
        "custom-test-targets": "自定义测试目标",
        "shell-configuration": "Shell 配置",
        "battery-state": "电池状态",
        "wifi-signal": "Wi-Fi 信号",
        "network-connection-state": "网络连接状态",
        "output-volume": "输出音量",
        "plugin-configuration": "插件配置",
        "encrypted-clipboard-history": "加密剪贴板历史",
        "local-encryption-key": "本机加密密钥",
        "user-exported-screenshots": "导出的截屏",
        "user-exported-recordings": "导出的录屏",
        "scan-result-cache": "扫描结果缓存",
        "application-identifiers": "应用标识",
        "preferred-volume-levels": "偏好音量",
        "switcher-configuration": "窗口切换配置",
        "shortcut-bindings": "快捷键绑定",
        "menu-bar-item-layout": "菜单栏布局",
        "performance-history": "性能历史",
        "cleanup-audit-history": "清理历史",
        "cleanup-staging-journal": "清理恢复记录",
        "pinned-settings": "已固定的设置",
        "settings-profiles": "设置配置文件",
        "setting-change-history": "设置更改历史",
        "coding-session-statistics": "编程会话统计",
        "cached-network-state": "网络状态缓存",
        "privacy-display-preference": "隐私显示设置",
        "shell-configuration-backup": "Shell 配置备份",
        "connected display": "已连接显示器",
        "built-in battery": "内建电池",
        "audio-output": "音频输出",
        "keyboard": "键盘",
        "controllable system fans": "可控制的系统风扇",
        "Sidecar-compatible Mac and display": "兼容随航的 Mac 与显示器",
        "network-connection": "网络连接",
    ]
}
