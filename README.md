# ReSettle

一个本地实现的 macOS 菜单栏小工具：**记住每个「显示器组合」下的窗口布局，屏幕睡醒/显示器接回来之后，把窗口放回原处。**

对标 [getresettle.com](https://getresettle.com) 的思路，但完全本地、无账号、无订阅、源码在此。

---

## 它解决的问题

macOS 在息屏 / 睡眠时会让外接显示器进入低功耗状态。这个过程里系统会「丢失」显示器连接信息，把窗口折叠到内屏、重排、改尺寸。唤醒后它自己也试图恢复，但经常恢复不全，或者要等十几秒才慢慢归位。

ReSettle 做的事很朴素：**你正常用电脑时它一直在旁边记小本本**；等显示器睡醒、系统折腾完了，它拿小本本对一眼，不对就按本子摆回去。

## 与 getresettle.com 的功能对照

| 官网描述的能力 | 这里的实现 |
| --- | --- |
| 无需先建 profile，用久了自动记住 | 后台逐秒采样，布局稳定即写入；不做任何前置配置 |
| 每个桌面组合各自一份记忆 | 按「显示器指纹集合」哈希成 `setupKey`，一个组合一个 profile |
| 记住窗口在哪块屏；同型号显示器按位置区分 | 用 EDID/UUID 指纹；重名时按屏幕坐标排序加序号 |
| 全屏窗口也能处理 | 检出 `AXFullScreen` → 退出全屏 → 搬到目标屏 → 再进全屏 |
| 可以为缺失的 App 启动程序 | **不做**（按你的选择：绝不擅自开程序） |
| 显示器分辨率不同也能用 | 存的是「相对该屏的归一化矩形」，尺寸变了按比例缩放并夹回可见区 |
| 菜单栏常驻、无 Dock 图标、可开机启动 | `LSUIElement` + `NSStatusItem`，登录项用 `SMAppService` |
| 一键「记住这个布局」 | `⌃⌥⌘L`，以及菜单项 |
| 撤销上一次恢复 | 菜单项「Undo Last Resettle」（恢复前会先拍一张） |

额外多做了两件事，因为你的环境有它们才成立：

- **TabGroups 协作**（见下）
- **可疑折叠保护**：宁可晚一拍，也不把「被系统挤成一团」的布局覆盖掉好记忆

## 工作原理

```
23:00  正常使用 → 每秒轻量比对 CGWindowList 指纹，窗口有变动就采一次 AX，写进 profile[3屏]
23:30  显示器进低功耗 → screensDidSleep → 冻结记录（否则会把挤成一团的布局覆盖掉好记忆）
08:00  唤醒 → 冻结记录 60s；同时开一个 35s 的「允许动手」窗口
       闸门全开才动手：
         ① 显示器事件安静 ≥ 2s（增删/分辨率/排列/Space 切换都算事件）
         ② 布局本身稳定 ≥ restoreDelay（默认 4s）
         ③ 距唤醒 ≥ restoreDelay + 1s
       ├─ 偏差 ≥ 阈值 → 恢复（TabGroups 壳优先 → 其它窗口 → 每窗口收敛）
       │                → 5s 后复核一次，还偏就补一轮（只补没到位的，最多 2 轮）
       └─ 没偏差     → 什么都不做
```

**为什么不按固定秒数等**：真实唤醒时 macOS 可能先接回一块屏、隔两秒再接回第二块，
中间那段「看起来稳定」的假象会骗过任何固定延时。所以这里等的是**信号安静**，不是时间流逝。
信号来自四个地方：`CGDisplayRegisterReconfigurationCallback`、`didChangeScreenParameters`、
`activeSpaceDidChange`（重建 Space 时会反复切）、以及窗口坐标本身的变化。

**为什么「允许动手」只有 35 秒**：够 macOS 重建完（通常 <15s），又不至于长到
把你醒来后自己拖窗口的动作也「纠正」回去。超过 35 秒就只观察、不再干预。

**为什么恢复后还要复核**：万一系统在我们的恢复之后又挪了一次窗口，5 秒后的复核会发现并补一轮。
第二轮只处理还没到位的窗口，已经摆好的不会被再挪一次。

几个关键设计：

**1. 记忆按「显示器组合」分桶。**
`setupKey = SHA256(排序后的显示器指纹)`. 显示器睡着时窗口被折叠到内屏，折叠后的布局自然落到另一个 key 上，**碰不到原来那份好记忆**。

**2. 冻结比记录更重要。**
唤醒后 60 秒内、显示器事件后 8 秒内、布局稳定不足 4 秒——一律不写盘。
另外还有 `CGDisplayIsAsleep` 全灭、屏幕锁定、配置变更中三种冻结条件。
再加一道 `looksCollapsed()`：如果记忆里跨多块屏，新采样却全挤在一块屏上、窗口数还没少，就要求「连续两次都这样」才认账。

> 这一条是防「**把半成品记成新基线**」的。系统把窗口挤成一团的那几秒如果被采信，
> 记忆就永久坏了——比「没恢复」严重得多。

**3. 恢复是「收敛」而不是「设一次」。**
有的 App 会因为最小尺寸、贴边吸附、"已经最大化"等原因把你设的值改掉。所以每个窗口设完都读回来核对，不对就重试，最多 3 轮。这是自测从 13/19 变成 19/19 的原因。

**4. 偏差判据位置严、尺寸松。**
位置差 > 8pt 就算乱；尺寸差要 > 48pt 才算。有些 App 每次都会把自己的高度改几个像素，那不是"乱"，不能因此触发一次全量搬动。

## TabGroups 协作

你装了 TabGroups（`tech.ripplex.tabgroups`）。它的模型是：一个 NSPanel 当「壳」，其他 App 的窗口被 AX 塞进壳里当「窗格」。读它的源码能看到两条硬事实：

- `Container.containerWindowFrameChanged` → `frame = newFrame; layout()` —— **壳一移动，它立刻重排所有窗格**
- `Container.handleChildEvent(.moved)` → 0.15s 后把跑偏的窗格拽回去

所以顺序很重要：**先还原容器壳，等它 `layout()` 排完，再还原其余窗口**。
此时窗格已经在正确位置，我们写同样的坐标，它的 `!current.equalTo(rect)` 判为 false，不会触发回弹。

反过来的做法（用「窗口是否被容器矩形包住」来排除窗格）**试过，不可行**：一块几乎铺满屏幕的容器会把背后所有普通窗口都误判成窗格，实测 19 个窗口被误排除掉 9 个。已废弃。

## 构建与运行

```bash
./build.sh              # swift build → 组装 dist/ReSettle.app → 签名
open dist/ReSettle.app  # 菜单栏出现图标
```

- 用 `security find-identity` 里找到的 **Apple Development 证书**签名。TCC 按「证书 + Bundle ID」记账，以后重编译不会被要求重新授权；没有证书就退回 ad-hoc（每次重编译可能要重授权）。
- 想开机自启：把 `dist/ReSettle.app` 拖到 `/Applications`，再在设置里打开 **Launch at login**（`SMAppService.mainApp` 要求 app 在标准位置）。

## 权限

需要 **辅助功能（Accessibility）**：这是读写其他 App 窗口位置的唯一途径，绕不过去。

首次启动会弹系统提示，去「系统设置 › 隐私与安全性 › 辅助功能」勾上 `ReSettle` 即可。

> ⚠️ 在终端里跑 `ReSettle --dump` 时，`Accessibility` 可能显示 **NOT granted**——这不是权限没给对。
> macOS 的 TCC 把授权记在「责任进程」上：从终端启动时，责任进程是终端，而终端没被授权。
> 看真实状态请用下面的 `SIGUSR1`，那是在 App 进程内部取的。

## 界面

菜单栏一个图标，没有主窗口。菜单：

| 项 | 说明 |
| --- | --- |
| `Home · 3 Displays · Settled` | 当前组合名 / 状态 |
| Remember This Layout `⌃⌥⌘L` | 立刻把当前布局记进当前组合 |
| Restore Now `⌃⌥⌘R` | 立刻按记忆恢复（不用等唤醒） |
| Undo Last Resettle | 撤销上一次恢复 |
| This Setup Is… | 给当前组合起名（Home / Office / …）或忘掉它 |
| Auto-Restore | 关掉后只记录、不自动动手 |
| Launch at Login | 登录自启 |
| Settings… `⌘,` | 延迟、忽略名单、已记住的组合列表 |

## 设置项

- **Wait after the displays come back**：唤醒后等多久才介入，默认 4s。这个值同时用作「布局稳定多久」的判据；
  低于 2s 无效（那是安全下限）。系统自己恢复得快就调小，慢就调大。
- **Ignored apps**：逗号分隔的 bundle id，例如 `com.apple.Safari, com.tinyspeck.slackmacgap`。

## 文件位置

`~/Library/Application Support/ReSettle/`

| 文件 | 内容 |
| --- | --- |
| `state.json` | 所有 profile + 设置（人类可读） |
| `resettle.log` | 运行日志，512KB 轮转 |
| `dump.txt` | `kill -USR1 <pid>` 生成的诊断快照（含菜单绑定状态） |
| `selftest.txt` | `kill -USR2 <pid>` 生成的端到端自检报告 |
| `simulation.txt` | `kill -WINCH <pid>` 生成的「唤醒冲突」模拟报告 |
| `menu.txt` | `kill -ALRM <pid>` 生成的菜单动作实测报告 |

## 诊断与自检

```bash
PID=$(pgrep -f "ReSettle.app/Contents/MacOS/ReSettle")
kill -USR1  $PID   # dump.txt：显示器、profile、当前布局、"跟记忆是否一致"、菜单绑定状态
kill -USR2  $PID   # 端到端自检：所有窗口挪开 48pt → 按记忆放回 → 逐窗口核对
kill -WINCH $PID   # 唤醒冲突模拟：见下
kill -ALRM  $PID   # 菜单动作实测：逐个 sendAction，并检查设置窗口是否真的开出来了
```

### `-WINCH` 在测什么

真息屏 5 秒是测不出问题的——Mac 不会真的断开显示器电源、重建桌面空间。所以这个测试不碰系统状态，
只按真实唤醒的**信号模式**喂给引擎：

```
t+0.0s  唤醒（wakeAt 置位，记录冻结 45s，开 60s 观察窗口）
t+0~6s  每 0.4s 一次"显示器还在动"事件（模拟 macOS 重建桌面空间）
t+2.0s  所有窗口整体挪 50pt（模拟系统第一波重排）
t+4.5s  再挪 50pt 且不还原（模拟系统最后没收尾）
```

期望：churn 期间**一次恢复都不能发生**、**一次写盘都不能发生**；安静下来后才允许恢复。
实机结果：

```
during the churn :
  restores fired  : 0   ✓ never fought macOS
  profile written : no ✓
after churn stops :
  restore started : yes, +10.0s
  windows back home: 18/18
RESULT: PASS
```

日志同时会打一行闸门放行时刻，第二天早上可以直接对时间线：

```
watch actionable +12.2s after wake (quiet 5.6s, stable 5.0s)
layout deviates from '3 Displays' — restoring (attempt 1/2, onlyDeviating: false)
restored 18 windows from '3 Displays' (moved 11, not converged 0)
```

`quiet` 是「距最后一次显示器/Space 事件多久」，`stable` 是「窗口坐标多久没动」。
如果这两个数明显小于 2s / restoreDelay，说明哪里漏了信号。

自检是这里唯一能「不睡觉也能验证搬运链路」的办法。当前实机结果：

```
windows sampled  : 19
nudged           : 17 windows really moved by (+48, +48)
restore applied  : 17 windows
verified         : 17/17 windows back within tolerance
RESULT: PASS
```

（19 里少掉的 2 个是全屏/最小化窗口，按要求跳过。）

## 已知限制

- **不启动缺失的 App**：记忆里有、但现在没运行的窗口，直接跳过。
- **最小化的窗口**：位置照记，但恢复时不动它（避免把最小化的窗口弹出来）。
- **同型号无序列号的显示器**：只能靠屏幕相对位置区分，物理换线会认错。
- **某些 App 拒绝被搬**：极少数窗口（自绘标题栏 / 强制吸附类）AX 写入会被自己改回，收敛 3 轮后放弃并记日志。
- **多用户同时登录**：只处理当前会话。
- **需要 macOS 13+**（`SMAppService`）。窗口搬运本身在更早版本也能用，但登录项不可用。

## 排错

**图标不见了**：`pgrep -lf ReSettle` 看进程在不在；不在就看 `resettle.log` 最后几行。

**恢复了但位置不对**：`kill -USR1` 看 `layout vs memory`，再核对 `Remembered windows` 与 `Live windows` 的差异。

**完全不动作**：先确认窗口菜单里没有 `Grant Accessibility Access…`（有就说明权限没给）。

**把状态搞乱了想重来**：退出 App，删掉 `state.json`，重开。
