# SideCast 开发进度

> 对应需求：[PRD.md](PRD.md) v0.2 · 当前阶段：**MVP**（Mac 官网版 + iPad 接收端）
> 开发分支：`feature/mvp`（每个里程碑提交一次，由你决定何时合并到 main）

## 里程碑

| 里程碑 | 内容 | 覆盖需求 | 状态 |
|---|---|---|---|
| M0 | 工程配置与代码骨架 | — | ✅ 完成 |
| M1 | 设备身份、加密通道、局域网/点对点发现、配对码配对 | FR-CONN-01/02/05~08/10/11 | ⏳ 进行中 |
| M2 | Mac 分应用音频捕获（Process Tap）与本地设备路由、分应用音量 | FR-ROUTE-01/02/04~10, FR-VOL-01~04 | 未开始 |
| M3 | 音频网络传输（低延迟 / 高音质）、iPad 播放、后台播放与锁屏卡片 | FR-MODE-01~04, FR-RECV-01~04 | 未开始 |
| M4 | 菜单栏 / 设置窗口完整界面、规则持久化、开机自启、中英文 | 6.8 节, FR-PERM-01~03, 7.5 节 | 未开始 |
| M5 | 免费 / 高级版：iPad 内购、Paddle 许可证、连接时解锁 | FR-PAY-01~05, FR-CONN-09 | 未开始 |
| M6 | 同 Apple ID 自动信任（iCloud） | FR-CONN-05 | 未开始 |

USB 有线（FR-CONN-03/04）属于 V1，不在 MVP 内。

## 更新日志

### 2026-11-23 · M0 工程配置与代码骨架
- 新建 `feature/mvp` 分支。
- 工程配置：开启网络收发权限（沙盒内）；新增 `Config/SideCast-Info.plist`（Bonjour 服务 `_sidecast._tcp`、音频捕获权限说明、后台音频）；Mac 端设为菜单栏应用（无 Dock 图标）；本地网络权限说明；工程语言加入 `en`、`zh-Hans`。
- 代码结构：
  - `SideCast/App`：入口。Mac 上是菜单栏 + 设置窗口，iPad 等平台是接收端窗口。
  - `SideCast/Shared`：两端共用（协议、加密、网络、音频编解码）。
  - `SideCast/Mac`：发送端（仅 macOS 编译）。
  - `SideCast/Receiver`：接收端（iOS / iPadOS / visionOS 编译）。
- macOS 与 iOS 模拟器均编译通过。

## 技术决策记录

| 决策 | 原因 |
|---|---|
| 单一多平台 target，用 `#if os(macOS)` 区分发送端/接收端 | 共用协议与加密代码；PRD 要求 Mac 接收模式与发送端是同一个 App |
| 官网版也保持 App 沙盒 | 同一份代码后续可直接上 Mac App Store；系统级虚拟音频设备（V1）再以独立驱动安装 |

## 已知问题 / 风险

（暂无）

## 需要你操作的事项

（暂无）
