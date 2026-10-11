<div align="center">
  <img src="docs/assets/logo-mactools-rounded.png" width="88" height="88" alt="MacTools 图标">
  <h1>MacTools</h1>
  <p><strong>Mac 常用工具，尽在菜单栏。</strong></p>
  <p>免费、开源、原生。自由组合面板，串联常用操作，按需添加工具。</p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
  <p>
    <a href="https://github.com/ggbond268/MacTools/releases"><img src="https://img.shields.io/github/v/release/ggbond268/MacTools?filter=v*" alt="最新应用版本"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-24292f" alt="macOS 14 或更高版本">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0-only 许可证"></a>
  </p>
  <p><a href="https://mactools.ggbond.app">官网</a> · <a href="https://github.com/ggbond268/MacTools/releases">下载</a> · <a href="docs/README.zh-CN.md">文档</a> · <a href="https://github.com/ggbond268/MacTools/issues">反馈</a></p>
</div>

<p align="center">
  <a href="docs/assets/screenshots/readme/dashboard-zh-dark.png"><img src="docs/assets/screenshots/readme/dashboard-zh-dark.png" width="32%" alt="系统状态面板，包含实时指标、进程、设备电量和快捷控件"></a>
  <a href="docs/assets/screenshots/readme/activity-zh-dark.png"><img src="docs/assets/screenshots/readme/activity-zh-dark.png" width="32%" alt="活动统计面板，包含输入次数、屏幕时间、应用使用情况与趋势"></a>
  <a href="docs/assets/screenshots/readme/controls-zh-dark.png"><img src="docs/assets/screenshots/readme/controls-zh-dark.png" width="32%" alt="显示、外观、音频和电源快捷控制面板"></a>
</p>

## 安装

```bash
brew install --cask mactools
```

也可从 [GitHub Releases](https://github.com/ggbond268/MacTools/releases) 下载。需要 **macOS 14 或更高版本**；部分插件需要更新的系统或兼容硬件。

打开 MacTools，在「**设置 → 插件市场**」中安装工具，再按习惯整理菜单栏面板。系统权限按需申请。

<details>
<summary>更新与 Nightly 构建</summary>

MacTools 会自动检查应用更新。通过 Homebrew 更新：

```bash
brew update
brew upgrade --cask --greedy mactools
```

可从 [`nightly-*` 预发布](https://github.com/ggbond268/MacTools/releases) 下载 `MacTools-Nightly.dmg`，体验开发中功能。Nightly 使用独立的偏好设置和插件，可与稳定版共存，适合测试使用；硬件控制仍作用于同一台 Mac。

</details>

## 按你的习惯组合

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>自定义面板</h3>
      <p>自由组合实时组件、快捷控件和功能行。拖拽调整顺序、跨面板移动，并为每个面板选择图标。</p>
      <a href="docs/assets/screenshots/readme/components-zh-dark.png"><img width="100%" src="docs/assets/screenshots/readme/components-zh-dark.png" alt="组件库中的系统状态预览，可添加到当前面板"></a>
    </td>
    <td width="50%" valign="top">
      <h3>自定义主题</h3>
      <p>选择内置配色，或导入 iTerm2、Base16/Base24 主题。分别设置浅色与深色主题，也可用图片或动画自定义菜单栏图标。</p>
      <a href="docs/assets/screenshots/readme/themes-zh-dark.png"><img width="100%" src="docs/assets/screenshots/readme/themes-zh-dark.png" alt="深色主题库，包含系统默认、One Dark、GitHub Dark 等配色"></a>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>自动化与工作流</h3>
      <p>将多个操作串联，设置等待时间与失败处理。支持按时间、日历事件、应用、电源、显示器和网络变化触发，并查看运行记录。</p>
      <a href="docs/assets/screenshots/readme/automation-zh-dark.png"><img width="100%" src="docs/assets/screenshots/readme/automation-zh-dark.png" alt="自动化编辑器中的多步骤工作流"></a>
    </td>
    <td width="50%" valign="top">
      <h3>丰富的插件市场</h3>
      <p>数十款插件，覆盖效率、显示、音频、清理与监控。按需安装和更新，在同一处管理设置与快捷键。</p>
      <a href="docs/assets/screenshots/readme/marketplace-zh-dark.png"><img width="100%" src="docs/assets/screenshots/readme/marketplace-zh-dark.png" alt="插件市场的分类筛选与已安装插件列表"></a>
    </td>
  </tr>
</table>

## 快速找到并执行操作

在**命令面板**中搜索操作、设置、工作流和插件。MacTools 内按 **⌘K**，或设置全局快捷键随时呼出。常用操作也能通过**操作网格**、键盘快捷键、鼠标映射和触控板手势执行，并与 Apple 快捷指令、已存脚本和 [Run Link](docs/url-scheme.md) 配合使用。

<p align="center"><a href="docs/assets/screenshots/readme/search-zh-dark.png"><img src="docs/assets/screenshots/readme/search-zh-dark.png" width="640" alt="中文命令面板搜索窗口相关操作、设置和插件"></a></p>

## 日常所需，按需取用

| 分类 | 主要功能 |
| --- | --- |
| 截图与剪贴板 | 截图标注、文字与二维码识别、贴图、滚动截图、区域录屏；本地加密剪贴板历史、文本片段和粘贴队列。 |
| 窗口与工作区 | 窗口切换与布局、应用启动台、台前调度、Finder 右键工具。 |
| 键盘、鼠标与触控板 | 输入映射、手势、应用快捷键、滚动调节、模拟中键、自动输入。 |
| 显示与外观 | 亮度与分辨率、Sidecar、原彩显示、夜览、隐藏刘海、菜单栏图标与程序坞管理。 |
| 音频与电源 | 系统、麦克风、应用和显示器音量；阻止休眠、风扇控制、充电上限、锁屏、睡眠和关机。 |
| 监控与日历 | 系统状态、设备电量、活动统计、AI 用量、网络检测，或将电量、Wi-Fi 与音量合并为一个可调尺寸的菜单栏图标，支持电量百分比、状态颜色、细分网络状态与蓝牙音频标记；日历与近期日程。 |
| 清理与维护 | 可视化浏览磁盘占用，将文件移到废纸篓前先审查大文件与文件夹，查看缓存、开发工具、应用数据与 IM 聊天工具的存储占用，磁盘与 Xcode 清理、Homebrew 与启动项管理、推出磁盘、清空废纸篓、退出应用、修复隔离应用、系统软重启、屏幕键盘清洁模式。 |
| 工具与配置 | 划词翻译、划词运行可编辑的 AI 提示词模板、Cloudflare R2 上传、zsh 编辑、Siri、可重复应用的 Mac 设置配置方案。 |

截图支持 macOS 14+；区域录屏和应用音量需要 macOS 15+。硬件控制取决于设备支持，详见[功能指南](docs/README.zh-CN.md)。

**带走你的配置：** 导入、导出偏好设置，保留本地备份，或通过云盘及共享文件夹同步支持的设置。应用支持 **12 种语言**，默认跟随系统。

## 终端中的 `mactools`

通过脚本或本地 AI Agent 发现操作、检查可用性并执行支持的操作，提供 **JSON 输出**、超时与取消。

CLI 目前是面向 **Apple 芯片 Mac 的 Nightly 实验性功能**。在支持的 Nightly 版本中，前往「**设置 → 通用 → 命令行**」安装并启用集成。Nightly 命令名为 `mactools-nightly`，普通稳定版尚未开放托管安装。

```bash
mactools-nightly doctor --json
mactools-nightly actions list --json
```

用 `actions describe <id>` 和 `actions availability <id>` 检查列表返回的操作，再通过 `actions run <id>` 执行。目前仅支持符合安全、后台、自动、可移植要求的无参数操作，暂不支持类型化参数和已存预设。

[CLI 安装指南](docs/testing/cli-nightly-distribution.md) · [AI Agent 使用指南](docs/cli/agent-usage.md) · [URL API](docs/url-scheme.md)

## 参与贡献

欢迎反馈问题、改进翻译、提出插件想法或提交 PR。Swift 6 / SwiftUI / AppKit 开发环境与流程见 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)，插件开发见[本地插件指南](docs/plugins/local-native-plugins.md)。

<a href="https://github.com/ggbond268/MacTools/graphs/contributors"><img src="https://contrib.rocks/image?repo=ggbond268/MacTools&max=120&columns=12" width="480" alt="MacTools 贡献者"></a>

## 隐私与许可

优先本地处理，不包含维护者运营的分析或广告服务。联网功能与系统权限说明见[隐私政策](https://mactools.ggbond.app/privacy-policy)。

采用 [GPL-3.0-only](LICENSE) 许可证。[许可范围](LICENSING.md)与[第三方声明](Sources/Resources/ThirdPartyNotices/README.md)列明依赖、素材和致谢。

<a href="https://hellogithub.com/repository/ggbond268/MacTools"><img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=6cddbd75f09848fb8848b58510394a5c&claim_uid=g4n28zqFcD0Vhw3&theme=small" alt="HelloGitHub 推荐项目"></a>
