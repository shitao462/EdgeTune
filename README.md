# EdgeTune

一个原生 macOS 音乐侧边浮窗原型。借鉴 Pulse 的贴边收起交互，界面与代码独立实现。

当前版本：**0.2**。

## 功能

- 316 × 110 像素的置顶浮窗；离开鼠标 3 秒后收为屏幕右侧 24 像素细条
- `⌥⌘M` 展开或收起；图钉可固定展开状态
- 在设置中选择网易云音乐、QQ 音乐、Spotify 或 Apple Music，查看歌曲信息并使用上一首、播放/暂停、下一首
- 设置登录 Mac 后自动启动（通过系统登录项管理）
- 从 LRCLIB 查询并显示当前时间对应的同步歌词（曲库中存在时）
- 菜单栏入口；不会占用 Dock

## 构建与运行

需要 macOS 14 或更新版本，以及 Apple Command Line Tools（提供 Swift 与 Clang 编译器）；无需 Node、Rust 或 Homebrew。构建时会从仓库内 `third_party/nowplaying-cli` 源码编译媒体适配工具。

```sh
chmod +x build.sh
./build.sh
open outputs/EdgeTune.app
```

歌词查询需要网络。媒体适配工具使用 macOS 私有的 MediaRemote 接口；系统更新后可能需要适配。它随应用一起构建，不需要额外安装。

## 当前范围

这是 macOS 原型，只在系统“正在播放”会话属于所选桌面客户端时显示和控制。播放器需要向 macOS 发布媒体信息；尚未完成各播放器的端到端验证。开机启动可能需要在系统设置的“登录项”中批准。Windows 版可复用歌词数据逻辑与界面方案，但系统媒体控制和浮窗需要单独实现与测试。

## 开源许可

本仓库采用 GPL-3.0。媒体适配工具来自 [nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli)，其源码和许可文件保留在 `third_party/nowplaying-cli`；它使用的 mediaremote-adapter 代码保留原有 BSD-3-Clause 通知。
