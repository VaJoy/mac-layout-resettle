import Foundation
import AppKit
import CoreGraphics

/// 大脑：持续观察显示器组合与窗口布局，在“变了又变了回来”的时机把布局放回原处。
///
/// 时间线（用户的实际场景）：
///   23:00 一切正常 → 每秒轻量采样，窗口有变动就记进 profile[3屏]
///   23:30 显示器进入低功耗 → 触发 freeze，**停止记录**（否则会把挤成一团的布局覆盖掉好记忆）
///   08:00 唤醒 → macOS 逐个把显示器接回来，重建 Space，把窗口重新铺开，这个过程可能好几秒
///          → 我们**不按秒数赌**，而是等「显示器事件安静 + 布局稳定 + 过了最小等待」三个条件同时满足
///          → 才比对记忆、才动手；动手后再等 5s 复核一次
///
/// 为什么不用固定的“等 N 秒”：真实唤醒时 macOS 可能先接回一块屏、隔两秒再接回第二块，
/// 中间那段“看起来稳定”的假象会骗过任何固定延时。
final class Engine {
    static let shared = Engine()

    let store = LayoutStore.shared
    private let queue = DispatchQueue(label: "com.vajoylan.resettle.engine", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    // MARK: 时间锚点（全部在 engine 队列上读写）

    /// 最近一次“系统级唤醒”（合盖/息屏恢复）。只在真的 wake 通知时更新。
    private var wakeAt = Date.distantPast
    /// 最近一次显示器相关事件（增删/分辨率/排列/Space 切换）。这是“macOS 还在动”的最可靠信号。
    private var lastDisplayEventAt = Date.distantPast
    /// 布局最后一次变化的时刻
    private var stableSince = Date.distantPast
    private var lastSignature: String?

    private var freezeUntil = Date.distantPast
    private var suspendRecordingUntil = Date.distantPast

    // MARK: 观察窗口

    private var watchUntil = Date.distantPast
    private var nextCheckAt = Date.distantPast
    private var restoreAttempts = 0
    private var didLogActionable = false

    // MARK: 其它状态

    private var screensAsleep = false
    private var asleepStreak = 0
    private var lastKey: String?
    private var lastSampledSignature: String?
    private var lastSampleAt = Date.distantPast
    private var isRestoring = false
    private var undoApps: [AppRecord] = []
    private var restoreSuppressedUntil = Date.distantPast
    private var suspectSignature: String?
    /// 自检用：累计恢复次数
    private(set) var restoreCount = 0

    private(set) var displays: [DisplayInfo] = []
    private(set) var statusText = "Starting…"
    private(set) var state: DisplayState = .settled

    var onStatusChange: ((String, DisplayState) -> Void)?
    var onRestored: ((Int) -> Void)?

    // MARK: 调参

    /// 显示器事件之后必须安静这么久，才认为 macOS 折腾完了
    private let displayQuiet: TimeInterval = 2.0
    /// 记录时更保守：显示器事件后 8 秒内一律不写盘
    private let recordQuiet: TimeInterval = 8.0
    /// 唤醒后这么长时间内不记录（系统重建桌面的窗口期）
    private let wakeRecordFreeze: TimeInterval = 60.0
    /// 允许动手的总时长。够 macOS 重建完（通常 <15s），又不会长到
    /// 把用户醒来后自己拖窗口的动作也「纠正」回去。
    private let watchWindow: TimeInterval = 35.0
    /// 最多纠正两轮（第二轮只补还没到位的窗口）
    private let maxRestoreAttempts = 2
    /// 恢复后多久复核
    private let verifyDelay: TimeInterval = 5.0

    private init() {}

    // MARK: - 生命周期

    func start() {
        DisplayManager.refreshNames()
        restoreSuppressedUntil = Date().addingTimeInterval(10)
        registerNotifications()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.4, repeating: 1.0, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        Log.info("engine started (trusted=\(AX.isTrusted))")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        for o in appObservers { NotificationCenter.default.removeObserver(o) }
        appObservers.removeAll()
        store.flushNow()
    }

    private func registerNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    Log.info("displays going to sleep — freezing recording")
                    self.screensAsleep = true
                    self.lastSignature = nil
                    self.stableSince = Date()
                }
            })
        }

        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    let now = Date()
                    Log.info("wake detected — freezing recording for \(Int(self.wakeRecordFreeze))s, watching for \(Int(self.watchWindow))s")
                    self.screensAsleep = false
                    self.wakeAt = now
                    self.lastDisplayEventAt = now
                    self.suspendRecordingUntil = now.addingTimeInterval(self.wakeRecordFreeze)
                    self.freezeUntil = now.addingTimeInterval(1.2)
                    self.lastSignature = nil
                    self.stableSince = now
                    self.beginWatch(now: now)
                }
            })
        }

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) {
                Engine.shared.handleDisplayReconfiguration(begin: true)
            } else if flags.contains(.addFlag) || flags.contains(.removeFlag)
                        || flags.contains(.enabledFlag) || flags.contains(.disabledFlag)
                        || flags.contains(.movedFlag) {
                Engine.shared.handleDisplayReconfiguration(begin: false)
            }
        }, nil)

        // AppKit 这一侧的信号：显示器参数一变（分辨率/排列/增减）就说明系统还在动
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.noteDisplayActivity() }
            })

        // 重建桌面空间时 macOS 会反复切 Space，这也是“还在动”的信号
        observers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.noteDisplayActivity() }
        })
    }

    /// 记录一次“系统还在动”
    private func noteDisplayActivity() {
        let now = Date()
        lastDisplayEventAt = now
        lastSignature = nil
        stableSince = now
        // 注意：这里**不延长**动手期限。否则用户每切一次 Space 都会把
        // 「允许纠正」的窗口重新打开，醒来后自己拖窗口就可能被纠正回去。
    }

    private func handleDisplayReconfiguration(begin: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if begin {
                let alreadyFrozen = Date() < self.freezeUntil
                if !alreadyFrozen { Log.info("display reconfiguration began") }
                self.freezeUntil = Date().addingTimeInterval(2.5)
            }
            self.noteDisplayActivity()
        }
    }

    private func beginWatch(now: Date) {
        watchUntil = now.addingTimeInterval(watchWindow)
        nextCheckAt = now.addingTimeInterval(1.0)
        restoreAttempts = 0
        didLogActionable = false
    }

    // MARK: - 两个闸门

    /// 能不能动手：三个条件必须同时满足
    private func canAct(now: Date) -> Bool {
        guard store.settings.autoRestore, AX.isTrusted, now >= restoreSuppressedUntil else { return false }
        let delay = max(store.settings.restoreDelay, 1.0)
        // 1) 系统安静了：显示器事件之后至少 displayQuiet 秒没动静
        guard now.timeIntervalSince(lastDisplayEventAt) >= displayQuiet else { return false }
        // 2) 唤醒后过了最小等待（用户在设置里调的那个数）
        guard now.timeIntervalSince(wakeAt) >= delay + 1.0 else { return false }
        // 3) 布局本身稳定了 delay 秒
        guard now.timeIntervalSince(stableSince) >= delay else { return false }
        return true
    }

    /// 能不能写盘：比动手更保守
    private func canRecord(now: Date) -> Bool {
        guard store.settings.autoRecord, AX.isTrusted, !isRestoring else { return false }
        guard now >= suspendRecordingUntil else { return false }
        // 唤醒后的一段时间里，桌面还在重建，任何采样都不能信
        guard now.timeIntervalSince(wakeAt) >= wakeRecordFreeze else { return false }
        guard now.timeIntervalSince(lastDisplayEventAt) >= recordQuiet else { return false }
        guard now.timeIntervalSince(stableSince) >= 4.0 else { return false }
        return true
    }

    // MARK: - 主循环

    private func tick() {
        let now = Date()
        let current = DisplayManager.snapshot()
        displays = current

        let awake = current.filter { !$0.asleep }
        if awake.isEmpty || screensAsleep || screenIsLocked() {
            if screensAsleep, !awake.isEmpty, awake.count == current.count {
                asleepStreak += 1
                if asleepStreak >= 6 {
                    Log.info("screens look awake again without a wake notification — resuming")
                    screensAsleep = false
                    asleepStreak = 0
                    wakeAt = now
                    suspendRecordingUntil = now.addingTimeInterval(wakeRecordFreeze)
                    beginWatch(now: now)
                }
            } else {
                asleepStreak = 0
            }
            lastSignature = nil
            stableSince = now
            publish(state: .asleep)
            return
        }
        asleepStreak = 0

        if now < freezeUntil {
            lastSignature = nil
            stableSince = now
            publish(state: .watching)
            return
        }

        let key = DisplayManager.setupKey(current)
        let signature = WindowSignature.current()

        // 显示器组合变了：插上/拔掉/接回来
        if key != lastKey {
            Log.info("setup changed → \(key) (\(current.map(\.name).joined(separator: ", ")))")
            lastKey = key
            lastSignature = signature
            stableSince = now
            lastDisplayEventAt = now
            lastSampledSignature = nil
            beginWatch(now: now)
            publish(state: .watching)
            return
        }

        if signature != lastSignature {
            lastSignature = signature
            stableSince = now
        }

        // 观察窗口：只有闸门全开才比对/动手
        if now < watchUntil, !isRestoring, now >= nextCheckAt, canAct(now: now) {
            nextCheckAt = now.addingTimeInterval(2.0)

            if !didLogActionable {
                didLogActionable = true
                let sinceWake = now.timeIntervalSince(wakeAt)
                let wakeText = sinceWake < 3600
                    ? String(format: "+%.1fs after wake", sinceWake)
                    : "on first check (no wake event)"
                Log.info(String(format: "watch actionable %@ (quiet %.1fs, stable %.1fs)",
                                wakeText,
                                now.timeIntervalSince(lastDisplayEventAt),
                                now.timeIntervalSince(stableSince)))
            }

            if let profile = store.profile(key), profile.windowCount > 0 {
                if restoreAttempts >= maxRestoreAttempts {
                    Log.info("giving up after \(restoreAttempts) attempts — leaving the layout alone")
                    watchUntil = .distantPast
                } else if LayoutDeviation.needsRestore(profile: profile, displays: current) {
                    let onlyDeviating = restoreAttempts > 0
                    Log.info("layout deviates from '\(profile.name)' — restoring (attempt \(restoreAttempts + 1)/\(maxRestoreAttempts), onlyDeviating: \(onlyDeviating))")
                    performRestore(profile: profile, key: key, onlyDeviating: onlyDeviating)
                    restoreAttempts += 1
                    return
                }
            } else {
                watchUntil = .distantPast
            }
        }

        // 记录
        guard canRecord(now: now) else {
            publish(state: .settled)
            return
        }
        if signature != lastSampledSignature || now.timeIntervalSince(lastSampleAt) > 12 {
            record(displays: current, key: key, signature: signature)
        }
        publish(state: .settled)
    }

    private func record(displays: [DisplayInfo], key: String, signature: String) {
        // 采样要花几百毫秒，期间显示器可能已经睡着/被拔了 —— 再确认一次
        let now = DisplayManager.snapshot()
        guard DisplayManager.setupKey(now) == key, !now.contains(where: \.asleep),
              canRecord(now: Date()), !isRestoring else {
            Log.info("skipping record: display state changed mid-sample")
            return
        }

        let apps = WindowSampler.sample(displays: now, ignored: store.settings.ignoredBundleIDs)
        lastSampledSignature = signature
        lastSampleAt = Date()
        guard !apps.isEmpty else { return }

        // 防呆：显示器“名义上还在、实际已经进低功耗”的那一瞬间，系统会把窗口全挤到一块屏。
        // 这种塌缩布局不能覆盖记忆 —— 除非它连续两次出现（那说明是真的人为变化）。
        if let existing = store.profile(key), looksCollapsed(existing, apps) {
            if suspectSignature == signature {
                suspectSignature = nil
                Log.info("collapse confirmed twice — accepting as the new layout")
            } else {
                suspectSignature = signature
                Log.info("suspicious collapse detected — waiting one more cycle before remembering")
                return
            }
        } else {
            suspectSignature = nil
        }

        if store.upsert(key: key, apps: apps, displays: displays) {
            Log.info("remembered \(apps.reduce(0) { $0 + $1.windows.count }) windows for \(key)")
        }
    }

    /// 记忆里跨多块屏，新采样却全部挤在一块屏上，且窗口数以多不少 → 大概率是系统折叠
    private func looksCollapsed(_ existing: Profile, _ fresh: [AppRecord]) -> Bool {
        let oldDisplays = Set(existing.apps.flatMap { $0.windows.map(\.displayKey) })
        guard oldDisplays.count >= 2 else { return false }
        let newDisplays = Set(fresh.flatMap { $0.windows.map(\.displayKey) })
        guard newDisplays.count == 1 else { return false }
        let newCount = fresh.reduce(0) { $0 + $1.windows.count }
        return newCount >= Int(Double(existing.windowCount) * 0.6)
    }

    // MARK: - 对外动作

    /// 自检期间暂停记录，免得把测试挪动的中间状态记进去
    func suspendRecording(seconds: TimeInterval) {
        queue.async { [weak self] in
            self?.suspendRecordingUntil = Date().addingTimeInterval(seconds)
            self?.lastSignature = nil
            self?.stableSince = Date()
        }
    }

    func rememberNow() {
        queue.async { [weak self] in
            guard let self else { return }
            let current = DisplayManager.snapshot()
            let key = DisplayManager.setupKey(current)
            self.displays = current
            self.lastKey = key
            let apps = WindowSampler.sample(displays: current, ignored: self.store.settings.ignoredBundleIDs)
            guard !apps.isEmpty else {
                Log.error("manual remember failed: no windows sampled (trusted=\(AX.isTrusted))")
                return
            }
            self.store.upsert(key: key, apps: apps, displays: current)
            self.store.flushNow()
            self.lastSampledSignature = WindowSignature.current()
            self.lastSampleAt = Date()
            self.lastDisplayEventAt = Date.distantPast
            self.stableSince = Date.distantPast
            Log.info("manual remember: \(apps.reduce(0) { $0 + $1.windows.count }) windows")
            self.publish(state: .settled)
        }
    }

    func restoreNow() {
        queue.async { [weak self] in
            guard let self else { return }
            let current = DisplayManager.snapshot()
            let key = DisplayManager.setupKey(current)
            self.displays = current
            guard let profile = self.store.profile(key), profile.windowCount > 0 else {
                Log.error("manual restore: no profile for \(key)")
                return
            }
            self.performRestore(profile: profile, key: key, onlyDeviating: false)
        }
    }

    func undoLastRestore() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.undoApps.isEmpty else {
                Log.info("undo: nothing to undo")
                return
            }
            let current = DisplayManager.snapshot()
            let key = DisplayManager.setupKey(current)
            let profile = Profile(id: key, name: "Undo", displayNames: current.map(\.name),
                                  displayKeys: current.map(\.key), apps: self.undoApps, updatedAt: Date())
            Log.info("undoing last restore")
            _ = Restorer.apply(profile: profile, displays: current, onlyDeviating: false)
            self.undoApps = []
            self.lastSignature = nil
            self.stableSince = Date()
            self.publish(state: .settled)
        }
    }

    func renameCurrentSetup(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = DisplayManager.setupKey(DisplayManager.snapshot())
            self.store.rename(key: key, to: name)
            self.publish(state: .settled)
        }
    }

    func forgetCurrentSetup() {
        queue.async { [weak self] in
            guard let self else { return }
            let key = DisplayManager.setupKey(DisplayManager.snapshot())
            self.store.remove(key: key)
            self.publish(state: .settled)
        }
    }

    // MARK: - 恢复

    private func performRestore(profile: Profile, key: String, onlyDeviating: Bool) {
        isRestoring = true
        publish(state: .restoring)

        undoApps = WindowSampler.sample(displays: displays, ignored: [])
        let outcomes = Restorer.apply(profile: profile, displays: displays, onlyDeviating: onlyDeviating)
        let moved = outcomes.filter { Geometry.needsAdjustment($0.before, $0.requested, tolerance: 1) }.count
        let failed = outcomes.filter { !$0.converged }

        isRestoring = false
        lastSignature = nil
        stableSince = Date()
        lastSampledSignature = nil
        restoreCount += 1
        // 恢复完先别急着收工：给 macOS 几秒，如果它又把窗口挪了，我们再补一轮
        nextCheckAt = Date().addingTimeInterval(verifyDelay)
        watchUntil = max(watchUntil, Date().addingTimeInterval(verifyDelay + 8))
        Log.info("restored \(outcomes.count) windows from '\(profile.name)' (moved \(moved), not converged \(failed.count))")
        for f in failed.prefix(8) {
            Log.info("  ! \(f.app) / \(f.title) wanted \(f.requested) got \(f.after)")
        }

        publish(state: .settled)
        DispatchQueue.main.async { [weak self] in self?.onRestored?(moved) }
    }

    // MARK: - 自检钩子（只在 SelfTest 里用）

    /// 模拟一次真实唤醒：设好时间锚点与闸门，但不真的让显示器睡
    func testSimulateWake() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.screensAsleep = false
            self.wakeAt = now
            self.lastDisplayEventAt = now
            self.suspendRecordingUntil = now.addingTimeInterval(self.wakeRecordFreeze)
            self.freezeUntil = now.addingTimeInterval(1.2)
            self.lastSignature = nil
            self.stableSince = now
            self.beginWatch(now: now)
            Log.info("TEST: simulated wake")
        }
    }

    /// 模拟 macOS 还在重建桌面（显示器事件不断）
    func testSimulateDisplayActivity() {
        queue.async { [weak self] in
            self?.noteDisplayActivity()
        }
    }

    func testRestoreCount() -> Int {
        queue.sync { restoreCount }
    }

    // MARK: - 状态

    private func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func publish(state newState: DisplayState) {
        let current = displays
        let key = current.isEmpty ? "" : DisplayManager.setupKey(current)
        let exists = store.profile(key) != nil
        let name = store.profile(key)?.name ?? DisplayManager.friendlyName(current)

        var text: String
        switch newState {
        case .asleep:
            text = "\(DisplayManager.friendlyName(current)) · Screen off"
        case .restoring:
            text = "\(name) · Restoring…"
        case .watching:
            text = "\(name) · Watching"
        case .settled, .noPermission:
            text = exists ? "\(name) · Settled" : "\(DisplayManager.friendlyName(current)) · Not remembered yet"
        }
        if !AX.isTrusted { text = "Accessibility permission needed" }

        guard text != statusText || newState != state else { return }
        statusText = text
        state = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(text, newState)
        }
    }
}
