import Foundation
import AppKit

/// 端到端自检：把所有窗口整体挪开，再用记忆把它们放回去，最后逐窗口核对。
/// 只通过 SIGUSR2 触发（`kill -USR2 <pid>`），结果写到 selftest.txt。
/// 这样能在不真的睡觉、不真的拔线的情况下验证「移动窗口」这条链路。
enum SelfTest {

    private static func key(_ bundleID: String, _ w: WindowRecord) -> String {
        "\(bundleID)#\(w.number.map(String.init) ?? "order-\(w.order)")"
    }

    private static func index(_ apps: [AppRecord]) -> [String: WindowRecord] {
        var map: [String: WindowRecord] = [:]
        for app in apps {
            for w in app.windows { map[key(app.bundleID, w)] = w }
        }
        return map
    }

    static func runRoundTrip() -> String {
        var out = ""
        func line(_ s: String) { out += s + "\n" }

        line("ReSettle self-test — restore round trip")
        line("────────────────────────────────────────")
        guard AX.isTrusted else {
            line("accessibility: NOT granted — abort")
            return out
        }

        let displays = DisplayManager.snapshot()
        let key0 = DisplayManager.setupKey(displays)
        let baseline = WindowSampler.sample(displays: displays)
        let byKey = index(baseline)
        line("setup            : \(key0) (\(displays.map(\.name).joined(separator: ", ")))")
        line("windows sampled  : \(byKey.count)")
        guard !byKey.isEmpty else { line("nothing to test"); return out }

        let profile = Profile(id: key0, name: "SelfTest",
                              displayNames: displays.map(\.name),
                              displayKeys: displays.map(\.key),
                              apps: baseline, updatedAt: Date())

        // 1) 统统挪开 48pt，模拟“被系统打乱”
        var nudged = 0
        var refusals: [String] = []
        for app in baseline {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .first(where: { !$0.isTerminated }) else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            guard let windows = AX.elements(axApp, kAXWindowsAttribute) else { continue }
            for (rec, win) in WindowMatcher.match(app.windows, windows) {
                if rec.fullscreen || rec.minimized { continue }
                guard let cur = AX.frame(win) else { continue }
                var moved = cur
                moved.origin.x += 48
                moved.origin.y += 48
                let actual = Restorer.applyConverging(win, to: moved)
                if Geometry.needsAdjustment(actual, moved, tolerance: 6) {
                    refusals.append("      \(app.name) / \(rec.title.isEmpty ? "(untitled)" : rec.title)  \(Int(cur.minX)),\(Int(cur.minY)) → \(Int(actual.minX)),\(Int(actual.minY))")
                } else {
                    nudged += 1
                }
                usleep(8_000)
            }
        }
        usleep(600_000)
        line("nudged           : \(nudged) windows really moved by (+48, +48)")
        if !refusals.isEmpty {
            line("  apps that refused to move (these can never be restored either):")
            refusals.prefix(12).forEach { line($0) }
        }

        // 2) 用记忆恢复
        let outcomes = Restorer.apply(profile: profile, displays: displays)
        usleep(800_000)
        line("restore applied  : \(outcomes.count) windows")

        // 3) 核对
        let after = index(WindowSampler.sample(displays: displays))
        var appNames: [String: String] = [:]
        for app in baseline { appNames[app.bundleID] = app.name }
        var checked = 0
        var ok = 0
        var failures: [String] = []

        for (k, rec) in byKey {
            if rec.fullscreen || rec.minimized { continue }
            guard let now = after[k] else { continue }
            checked += 1
            let f = rec.localFrame
            let g = now.localFrame
            let dx = abs(g.x - f.x), dy = abs(g.y - f.y)
            let dw = abs(g.w - f.w), dh = abs(g.h - f.h)
            if max(dx, dy) <= 6 && max(dw, dh) <= 24 {
                ok += 1
            } else {
                let bundle = String(k.split(separator: "#").first ?? "")
                failures.append(String(format: "  ✗ %@ / %@\n      want [%.0f,%.0f %.0fx%.0f]  got [%.0f,%.0f %.0fx%.0f]  Δ(%.0f,%.0f,%.0f,%.0f)",
                                       (appNames[bundle] ?? bundle) as NSString,
                                       (rec.title.isEmpty ? "(untitled)" : rec.title) as NSString,
                                       f.x, f.y, f.w, f.h, g.x, g.y, g.w, g.h, dx, dy, dw, dh))
            }
        }

        line("verified         : \(ok)/\(checked) windows back within tolerance")
        if !failures.isEmpty {
            line("mismatches:")
            failures.prefix(25).forEach { line($0) }
        }
        line(ok == checked ? "RESULT: PASS" : "RESULT: CHECK THE MISMATCHES ABOVE")
        return out
    }

    static func writeToFile() {
        let text = runRoundTrip()
        Paths.ensureSupportDir()
        try? text.write(to: Paths.supportDir.appendingPathComponent("selftest.txt"),
                        atomically: true, encoding: .utf8)
        Log.info("self-test finished")
    }

    // MARK: - 模拟“唤醒 + 系统重建桌面”

    /// 核心问题：macOS 唤醒后会花几秒重建桌面空间，期间窗口会被反复挪动。
    /// 如果 ReSettle 在这段时间里动手，就会跟系统对着干；更糟的是可能把半成品布局记成新基线。
    ///
    /// 这个测试不改系统状态，只按真实唤醒的**信号模式**喂给引擎：
    ///   t+0.0s  唤醒（wakeAt 置位，记录冻结 45s，开观察窗口）
    ///   t+0~6s  每 0.4s 一次“显示器还在动”事件（模拟 macOS 重建）
    ///   t+2.0s  把窗口整体挪 50pt（模拟系统第一波重排）
    ///   t+4.5s  停在错位上不还原（模拟系统最后没收尾）
    /// 期望：
    ///   - 0~6s 内一次恢复都不能发生
    ///   - 这 6s 内也不能写盘（记忆必须原封不动）
    ///   - 安静下来后，才允许恢复，并把窗口放回原处
    static func runWakeSimulation() -> String {
        var out = ""
        func line(_ s: String) { out += s + "\n" }

        line("ReSettle wake simulation — does it fight macOS?")
        line("────────────────────────────────────────")
        guard AX.isTrusted else {
            line("accessibility: NOT granted — abort")
            return out
        }

        let displays = DisplayManager.snapshot()
        let key = DisplayManager.setupKey(displays)
        let baseline = WindowSampler.sample(displays: displays)
        let total = baseline.reduce(0) { $0 + $1.windows.count }
        guard total > 0 else { line("no windows — abort"); return out }

        // 让记忆 == 当前布局，作为比对基准
        if let existing = LayoutStore.shared.profile(key), existing.apps != baseline {
            line("note             : profile differs from live layout — syncing first (same as Remember)")
        }
        LayoutStore.shared.upsert(key: key, apps: baseline, displays: displays)
        LayoutStore.shared.flushNow()
        line("baseline windows : \(total)")

        let countAtStart = Engine.shared.testRestoreCount()
        Engine.shared.testSimulateWake()
        usleep(300_000)

        var prematureRestores = 0
        var wave1Done = false
        var wave2Done = false
        var recordedDuringChurn = false
        let t0 = Date()

        while Date().timeIntervalSince(t0) < 6.5 {
            Engine.shared.testSimulateDisplayActivity()
            let elapsed = Date().timeIntervalSince(t0)

            if !wave1Done, elapsed > 2.0 {
                wave1Done = true
                let n = shiftAll(baseline, displays, dx: 50, dy: 50)
                line("t+2.0s  macOS wave 1: moved \(n) windows")
            }
            if !wave2Done, elapsed > 4.5 {
                wave2Done = true
                let n = shiftAll(baseline, displays, dx: 50, dy: 50)
                line("t+4.5s  macOS wave 2: moved \(n) more windows")
            }
            if Engine.shared.testRestoreCount() > countAtStart { prematureRestores += 1 }

            // 记录有没有偷偷发生（记忆应该还是 baseline）
            if let p = LayoutStore.shared.profile(key), p.apps != baseline {
                recordedDuringChurn = true
            }
            usleep(400_000)
        }

        line("")
        line("during the churn :")
        line("  restores fired  : \(prematureRestores)   \(prematureRestores == 0 ? "✓ never fought macOS" : "✗ CONFLICT")")
        line("  profile written : \(recordedDuringChurn ? "yes ✗ (半成品布局被记下了)" : "no ✓")")

        // 停止喂事件，等闸门自己放行
        let t1 = Date()
        var actedAfter = false
        var actedAt: TimeInterval = 0
        while Date().timeIntervalSince(t1) < 25 {
            if Engine.shared.testRestoreCount() > countAtStart {
                actedAfter = true
                actedAt = Date().timeIntervalSince(t1)
                break
            }
            usleep(400_000)
        }
        line("")
        line("after churn stops :")
        line(String(format: "  restore started : %@", actedAfter ? String(format: "yes, +%.1fs", actedAt) : "no (nothing to fix?)"))

        // 复核页面是否回到 baseline
        usleep(4_000_000)
        let after = index(WindowSampler.sample(displays: displays))
        var checked = 0, ok = 0
        var misses: [String] = []
        for (k, rec) in index(baseline) {
            if rec.fullscreen || rec.minimized { continue }
            guard let now = after[k] else { continue }
            checked += 1
            let f = rec.localFrame, g = now.localFrame
            if abs(g.x - f.x) <= 6, abs(g.y - f.y) <= 6, abs(g.w - f.w) <= 24, abs(g.h - f.h) <= 24 {
                ok += 1
            } else {
                misses.append(String(format: "      ✗ %@  want [%.0f,%.0f %.0fx%.0f] got [%.0f,%.0f %.0fx%.0f]",
                                     (rec.title.isEmpty ? "(untitled)" : rec.title) as NSString,
                                     f.x, f.y, f.w, f.h, g.x, g.y, g.w, g.h))
            }
        }
        line("  windows back home: \(ok)/\(checked)")
        for m in misses.prefix(6) { line(m) }

        let pass = prematureRestores == 0 && !recordedDuringChurn && ok == checked && checked > 0
        line("")
        line(pass ? "RESULT: PASS" : "RESULT: CHECK ABOVE")
        return out
    }

    /// 把每个窗口再挪一次（模拟系统重排）
    @discardableResult
    private static func shiftAll(_ apps: [AppRecord], _ displays: [DisplayInfo], dx: CGFloat, dy: CGFloat) -> Int {
        var moved = 0
        for app in apps {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .first(where: { !$0.isTerminated }) else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            guard let windows = AX.elements(axApp, kAXWindowsAttribute) else { continue }
            for (rec, win) in WindowMatcher.match(app.windows, windows) {
                if rec.fullscreen || rec.minimized { continue }
                guard let cur = AX.frame(win) else { continue }
                var movedRect = cur
                movedRect.origin.x += dx
                movedRect.origin.y += dy
                _ = AX.setFrame(win, movedRect)
                moved += 1
                usleep(8_000)
            }
        }
        return moved
    }

    static func writeSimulationToFile() {
        let text = runWakeSimulation()
        Paths.ensureSupportDir()
        try? text.write(to: Paths.supportDir.appendingPathComponent("simulation.txt"),
                        atomically: true, encoding: .utf8)
        Log.info("wake simulation finished")
    }
}
