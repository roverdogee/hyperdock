# HyperDock

[English](README.md) | **简体中文**

将指针悬停在 Dock 图标上，即可预览该应用的所有窗口——包括已最小化、以及位于其他桌面（Space）的窗口——并点击直达目标窗口。

HyperDock 是 macOS 菜单栏代理（agent）应用：自身不出现在 Dock 中，在后台运行，通过菜单栏图标或全局快捷键打开设置。

| | |
|---|---|
| **版本** | 1.0.0 |
| **平台** | macOS 26.0+，Apple Silicon（`arm64`） |
| **Bundle ID** | `com.hyperdock.HyperDock` |
| **界面语言** | 英语、简体中文 |

---

## 功能

### 窗口预览
- 悬停任意 Dock 图标，弹出气泡式窗口缩略图
- 可包含所有 Space 上的窗口、最小化/隐藏窗口，以及（可选）浮动面板
- 在卡片上停留更久可显示全尺寸预览
- 点击卡片激活对应窗口；可选每张卡片的关闭按钮
- 对非当前桌面的窗口显示 Space 指示

### Dock 项快捷操作
- 将「修饰键 + 鼠标按键」（左键 / 中键 / 右键）绑定到：退出、隐藏、新建窗口、显示全部窗口、全部最小化、重新启动等
- 支持「所有 Dock 项」全局规则，以及按应用覆盖

### 窗口管理
- **边缘吸附**：按住「移动」修饰键拖拽窗口到屏幕边缘时吸附（开启时会关闭系统自带的拖到边缘分屏，避免两套逻辑冲突）
- **键盘吸附**（默认 ⌃⌥ + 方向键 / Return / 小键盘 / `G` 网格平铺）
- **移动窗口**：按住修饰键拖拽（默认 ⌃⌥）
- **调整大小**：按住修饰键拖拽（默认 ⌃⌥⇧）
- 可配置平铺网格（列、行、间距）

### 外观与行为
- 浅色 / 深色 / 跟随系统
- 气泡大小、每行预览数、动画、三角指针、高光渐变等
- 登录时启动、隐藏菜单栏图标（下次启动会恢复）、任意位置打开设置（默认 ⌃⌥⌘H）

---

## 系统要求

- **macOS 26.0** 或更高
- **Apple Silicon** Mac
- 从源码构建需要 **Xcode** 命令行工具
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**（`brew install xcodegen`）

### 权限

| 权限 | 是否必须 | 用途 |
|---|---|---|
| **辅助功能（Accessibility）** | 必须 | 读取 Dock 图标；激活、关闭、移动、缩放窗口 |
| **屏幕录制（Screen Recording）** | 可选 | 实时缩略图与窗口标题 |

没有辅助功能时 HyperDock 无法工作。没有屏幕录制时仍可切换窗口，但缩略图和标题会受限。

请在 **系统设置 → 隐私与安全性** 中授权。首次启动会显示欢迎流程引导完成授权。

---

## 安装（源码构建）

```bash
# 可选但强烈建议：创建本地稳定签名，避免每次重建后
# 辅助功能 / 屏幕录制权限因 ad-hoc 签名变化而失效
./scripts/setup-signing.sh

# Debug 构建并安装到 /Applications/HyperDock.app
./scripts/build.sh

# Release 构建
CONFIG=Release ./scripts/build.sh

# 务必通过 Launch Services 启动（不要从 shell 直接跑二进制）
open /Applications/HyperDock.app
```

> **重要：** 从终端直接启动二进制会继承*终端*的 TCC 授权，权限会看起来已开启、实际并未授予应用。请始终使用 `open` 或双击 App 启动。

### 发布包（DMG）

```bash
./scripts/release.sh
```

生成 `dist/HyperDock.dmg`。若本机有 **Developer ID Application** 证书及公证凭据（`HyperDockNotary` 配置），脚本会额外签名并公证；否则产出适合本机使用的本地签名镜像。

推送到 `main` 时，GitHub Actions 会构建并把同样的 DMG 发布到 [Releases](../../releases)。CI 产物通常是 **ad-hoc 签名**（runner 上一般没有 Developer ID）。从浏览器或 AirDrop 下载的 DMG 可能被 Gatekeeper 拦截（带有 quarantine 标记）。打开前可先清除：

```bash
xattr -d com.apple.quarantine /path/to/HyperDock.dmg
```

然后打开磁盘映像，将 HyperDock 拖入「应用程序」即可。

### 应用图标

```bash
swift scripts/make-icon.swift /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Sources/HyperDock/Resources/AppIcon.icns
```

---

## 使用

1. 安装并打开 HyperDock。
2. 完成欢迎步骤，授予**辅助功能**（以及可选的**屏幕录制**）。
3. 将指针悬停在 Dock 图标上打开预览气泡；点击窗口卡片切换到该窗口。
4. 通过菜单栏图标打开设置，或使用全局快捷键（默认 **⌃⌥⌘H**）。
5. 若隐藏了菜单栏图标，再次启动 HyperDock（或使用快捷键）即可恢复入口。

---

## 项目结构

```
hyperdock/
├── project.yml                 # XcodeGen 工程定义
├── scripts/
│   ├── build.sh                # 生成工程、构建、安装、签名
│   ├── release.sh              # Release 构建 + DMG（可选公证）
│   ├── setup-signing.sh        # 本地自签名，稳定 TCC
│   └── make-icon.swift         # 生成 AppIcon.iconset
├── Sources/HyperDock/
│   ├── App/                    # 入口、状态栏
│   ├── Core/                   # 偏好、权限、本地化、登录项
│   ├── Dock/                   # Dock 监听、快捷操作、Dock 调优
│   ├── Settings/               # 设置与欢迎界面
│   ├── System/                 # 辅助功能 (AX)、CGS 私有 SPI、调度中心检测
│   ├── Thumbnails/             # ScreenCaptureKit 缩略图
│   ├── UI/                     # 预览气泡、卡片、全尺寸预览
│   ├── Windows/                # 吸附、网格、窗口索引与操作
│   └── Resources/              # Info.plist、entitlements、图标、字符串
└── Tests/HyperDockTests/       # 契约测试（生命周期、输入）
```

Xcode 工程在每次构建时由 **XcodeGen 生成**。请勿提交 `HyperDock.xcodeproj/`、`.build/`、`dist/`（已在 `.gitignore` 中忽略）。

---

## 开发

```bash
# 仅生成 Xcode 工程
xcodegen generate

# 推荐使用脚本构建
./scripts/build.sh

# 生成后可用 Xcode 打开
open HyperDock.xcodeproj
```

### 说明

- **App Sandbox 必须关闭。** 沙盒进程无法对其他应用调用 Accessibility。
- **签名：** `scripts/build.sh` 优先使用 `setup-signing.sh` 创建的 “HyperDock Local Signing” 身份，否则回退 ad-hoc。基于证书的签名可让 TCC 授权跨重建保留。
- **Swift 6**，默认 Actor 隔离为 `MainActor`，严格并发。
- 界面语言可跟随系统，或强制英语 / 简体中文（即时生效，无需重启）。

---

## 设置一览

| 面板 | 内容 |
|---|---|
| **通用** | 登录启动、预览开关、激活延迟、包含范围、排序、悬停行为、重置全部 |
| **外观** | 主题、标签、气泡布局、动画 |
| **Dock 项** | 修饰键 + 点击快捷操作（全局与按应用） |
| **窗口管理** | 边缘吸附、键盘吸附、移动/缩放修饰键、平铺网格 |
| **高级** | 暂停 HyperDock、时序、缩略图质量/实时刷新、Dock 自动隐藏加速、设置快捷键 |
| **关于** | 版本、语言、权限状态 |

---

## 卸载

1. 从菜单栏图标退出 HyperDock（或在设置中关闭登录启动）。
2. 删除应用：`rm -rf /Applications/HyperDock.app`
3. 可选清理：

```bash
# 偏好设置
defaults delete com.hyperdock.HyperDock 2>/dev/null || true
```

若开启过「立即显示隐藏的 Dock」，请先关闭该选项再退出，以便恢复系统 Dock 默认值；也可在 **通用 → 重置所有设置…** 中一并还原。

---

## 许可证

本项目采用 [MIT License](LICENSE) 开源许可。
