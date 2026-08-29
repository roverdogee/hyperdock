# Apple Silicon 版 HyperDock

[English](README.md) | **简体中文**

这是一个面向 Apple Silicon、以 Swift 原生实现的 HyperDock 窗口预览工具。将指针
悬停在正在运行的应用 Dock 图标上，即可查看它的窗口（包括最小化窗口和其他 Space
中的窗口），点击缩略图便可切换。

本项目通过对已经停止维护的 HyperDock 1.8 进行逆向研究和行为观察而开发，是独立
编写的实现，并非原 HyperDock 源码。详情见
[原版 HyperDock 说明](ORIGINAL_HYPERDOCK_NOTICE.md)。

| | |
|---|---|
| **版本** | 1.0.0 |
| **平台** | macOS 26.0+，Apple Silicon（`arm64`） |
| **Bundle ID** | `com.hyperdock.HyperDock` |
| **界面语言** | 英语、简体中文 |

## 功能

- Dock 悬停气泡，以及固定区域、等比例适配的窗口缩略图
- 显示其他 Space、最小化及隐藏的窗口
- 悬停后显示全尺寸预览
- 点击激活窗口、悬停关闭按钮、加号新建窗口
- 预览气泡内的键盘导航和滚动手势
- 四种参考原版的外观：自动、经典、鲜明浅色、鲜明深色
- 可调预览尺寸、每行数量、动画、标签、时序和实时刷新
- 可选的隐藏 Dock 快速显示
- 菜单栏控制、登录启动和全局设置快捷键

本项目特意不包含原 HyperDock 的窗口吸附/平铺、修饰键拖拽窗口管理，以及按应用
配置的 Dock 点击动作。

## 原版 HyperDock 素材

公开仓库不会再分发原应用中受版权保护的图片。用户可从自己合法取得的 HyperDock
副本中提取关闭按钮图片，并放入：

```
Sources/HyperDock/Resources/OriginalHyperDock/Helper/
```

构建时会使用 `closebox.png`、`closebox@2x.png`、`closebox_white.png`、
`closebox_white@2x.png`、`closebox_white_pressed.png` 和
`closebox_white_pressed@2x.png`。该目录已被 git 忽略；素材不存在时会自动使用
SF Symbols 原生绘制版本，项目仍可正常构建和运行。

## 系统要求与权限

- Apple Silicon Mac，macOS 26.0 或更高
- Xcode 命令行工具
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- **辅助功能**：必须，用于读取 Dock 图标以及激活或关闭窗口
- **屏幕录制**：可选，用于缩略图和窗口标题

## 构建与安装

```bash
# 建议仅执行一次：创建稳定的本地签名，使重建后无需反复授权
./scripts/setup-signing.sh

# 生成工程、构建、签名并安装到 /Applications/HyperDock.app
./scripts/build.sh

# Release 构建
CONFIG=Release ./scripts/build.sh

# 通过 Launch Services 启动
open /Applications/HyperDock.app
```

不要从终端直接运行可执行文件，否则 macOS 可能把隐私授权行为归到终端，而不是应用。

运行测试：`swift test`。

## 项目结构

```
Sources/HyperDock/
├── App/          # 生命周期与菜单栏
├── Core/         # 偏好、权限、本地化、应用操作
├── Dock/         # Dock 悬停检测与可选自动隐藏调优
├── Settings/     # 设置和首次运行引导
├── System/       # 辅助功能及 macOS 窗口/Space 集成
├── Thumbnails/   # ScreenCaptureKit 捕获与缓存
├── UI/           # 预览气泡、卡片和全尺寸预览
└── Windows/      # 窗口发现与数据模型
```

Xcode 工程由 `project.yml` 生成；生成文件、构建产物和本地原版素材均不会提交。

## 许可证

独立编写的源代码采用 [MIT License](LICENSE)。HyperDock 名称及任何原版素材仍归其
权利人所有，不属于 MIT 授权范围。
