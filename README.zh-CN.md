# 松烟（Songyan）

![CI](../../actions/workflows/ci.yml/badge.svg)

[English](README.md)

松烟是一款基于 [RIME 中州韵](https://rime.im) 引擎的 iPhone / iPad 输入法。RIME 输入方案能打什么，松烟就能打什么：拼音、双拼、注音、仓颉、粤拼、日语等等。引擎直接在键盘里、在你的设备上运行。引擎、输入方案和文件格式与 [松烟 Android 版](https://github.com/Suzukaa-a/songyan-android) 通用。

<p>
  <img src=".github/screenshots/keyboard-14.png" width="240" alt="14 键键盘输入 nihao">
  <img src=".github/screenshots/keyboard-9.png" width="240" alt="9 键键盘输入 zhong">
  <img src=".github/screenshots/home.png" width="240" alt="主 App 首页">
</p>

## 安装

1. 从 [Releases](https://github.com/Suzukaa-a/songyan-ios/releases) 下载 IPA，用 AltStore、Sideloadly 这类能用你自己的 Apple ID 重新签名的工具安装；也可以自己构建（见下文）。需要 iOS 17.0 或更高版本。
2. 在「设置 → 通用 → 键盘 → 键盘」中添加松烟，并打开「允许完全访问」。完全访问只用来让键盘和松烟 App 共用你的输入方案和设置。

## 能做什么

- **内置全拼和小鹤双拼**，可用 26 键、14 键、18 键、9 键。
- **任何 RIME 输入方案**：从推荐列表添加（雾凇拼音、万象拼音、注音、仓颉、速成、粤拼、日语カギロイ），也可以从文件或链接导入自己的方案。你确认后才会下载。导入的方案还能用注音、仓颉、日语罗马字和假名键盘。
- **简体或繁体输出**（也有台湾、香港用字），可按输入方式分别切换。
- **合并键左右滑**可以打出其中任一个字母，还可以在字母键上显示双拼提示。
- **布局和外观**：在 App 里编辑键盘布局，用[网页外观编辑器](https://suzukaa-a.github.io/songyan-themes/)制作外观。外观文件 iOS 和 Android 通用。
- **可选功能**：错键纠正、联想、语法模型，以及学到的词的备份（与 Android 版通用）。
- 界面提供简体中文、繁体中文和日语。

## 隐私

松烟不收集任何个人数据，也不向开发者或任何人发送数据。键盘本身从不联网；只有你在 App 里主动操作时才会联网：下载或更新输入方案，或者下载词库、模型文件。你输入的内容和学到的词只留在你的设备上。

## 已知问题

- **键盘上方多出 17 pt 空白（iOS 26、27）**：键盘弹出时切换 App，或从带顶栏的系统键盘切到松烟后，iOS 可能在第三方键盘上方加一条空白。切到表情键盘再切回来，或重新打开当前 App 即可恢复。已反馈给 Apple（[论坛](https://developer.apple.com/forums/thread/843093)，FB24460699、FB25094825）。
- **Safari 地址栏补全**：Safari 补全网址时，删除键会删掉最后一个字母，Safari 随即重新补全。

## 从源码构建

打开 `Songyan.xcodeproj`，或者运行 `make sim-stage`，不需要开发者账号就能在模拟器上构建并安装。环境要求、检查命令和项目规则见 [CONTRIBUTING.md](CONTRIBUTING.md)，模块结构见 [ARCHITECTURE.md](ARCHITECTURE.md)，模拟器自动化见 [DEBUG.md](DEBUG.md)。安全问题请按 [SECURITY.md](SECURITY.md) 报告。

## 许可

Copyright © 2026 Suzukaa-a。采用 [GPL-3.0-only](LICENSE) 许可。第三方组件及其许可见 [Resources/Legal/ThirdPartyNotices.txt](Resources/Legal/ThirdPartyNotices.txt) 与 [Resources/Legal/ThirdPartyNotices-iOS.txt](Resources/Legal/ThirdPartyNotices-iOS.txt)。
