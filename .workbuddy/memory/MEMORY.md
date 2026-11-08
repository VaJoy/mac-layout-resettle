# ReSettle 项目长期备注

本地重实现的 macOS 窗口布局记忆/还原菜单栏工具（对标 getresettle.com）。
Swift Package + `build.sh` 组装 .app，无第三方依赖。

## 架构不变量

- **一屏组合 = 一 profile**，id 是显示器指纹集合的 SHA256 前 12 位；不要改成按显示器数量或名字分桶。
- **睡时必须冻结记录**，否则会把系统折叠后的烂布局覆盖掉好记忆。
- **唤醒后不准按固定秒数动手**：必须等「显示器事件安静 + 窗口坐标稳定 + 过了最小等待」三个闸门同时满足。
  信号源：`CGDisplayRegisterReconfigurationCallback` / `didChangeScreenParameters` /
  `activeSpaceDidChange` / `CGWindowList` 坐标变化。允许动手的窗口只有 35s。
- **恢复要收敛**（设值 → 读回 → 重试，最多 3 轮），单次 `AXUIElementSetAttributeValue` 成功率只有 ~70%。
- **位置判据严、尺寸判据松**（8pt / 48pt），否则每次唤醒都会误触发全量搬动。
- **TabGroups 优先**：`tech.ripplex.tabgroups` 的容器壳必须先还原，它 `layout()` 会自动排窗格；不要试图直接搬窗格。

## 构建/调试约定

- `./build.sh` → `dist/ReSettle.app`；签名用 keychain 里的 Apple Development 证书（TCC 授权可跨重编译保留）。
- 诊断走信号：`kill -USR1 <pid>` = 快照，`kill -USR2 <pid>` = 端到端自检。都在 `~/Library/Application Support/ReSettle/`。
- 状态文件 `state.json` 人类可读，删掉即重置。

## 环境

用户机器：macOS 27.2 / M4 Max / Xcode 27.1 / Swift 6.4，3 屏（内置 + P2768T 横 + VX2479 竖）。
已装 TabGroups（窗口拼贴，源码在 `TabGroups/`）。
