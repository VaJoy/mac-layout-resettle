import Foundation
import AppKit

/// 判断“现在这个布局需不需要动手”。
/// 只在唤醒/接回显示器后的观察窗口里调用，避免用户正常挪窗口时被强行纠正。
enum LayoutDeviation {

    static func needsRestore(profile: Profile, displays: [DisplayInfo]) -> Bool {
        guard AX.isTrusted else { return false }

        var total = 0
        var bad = 0

        for app in profile.apps {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .first(where: { !$0.isTerminated }) else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            guard let windows = AX.elements(axApp, kAXWindowsAttribute) else { continue }

            for (rec, win) in WindowMatcher.match(app.windows, windows, expected: expectedTarget(displays)) {
                guard let display = displays.first(where: { $0.key == rec.displayKey }) else { continue }
                total += 1

                // 全屏窗口只看“在哪块屏”，不比对坐标（它本来就不听坐标的）
                if rec.fullscreen {
                    guard let cur = AX.frame(win) else { continue }
                    if let actual = DisplayManager.display(for: cur, in: displays), actual.key != display.key {
                        bad += 1
                    }
                    continue
                }

                guard let cur = AX.frame(win), !cur.isEmpty else { continue }
                let target = Geometry.target(for: rec, on: display)
                if Geometry.isBadlyOff(cur, target) { bad += 1 }
            }
        }

        guard total > 0 else { return false }
        // 1~2 个窗口：至少 1 个错位；更多窗口：至少 2 个错位才算“乱了”
        let threshold = total <= 2 ? 1 : 2
        return bad >= threshold
    }

    /// 给匹配器一个“这个窗口本该在哪”的参考答案
    static func expectedTarget(_ displays: [DisplayInfo]) -> (WindowRecord) -> CGRect? {
        { rec in
            guard let d = displays.first(where: { $0.key == rec.displayKey }) else { return nil }
            return Geometry.target(for: rec, on: d)
        }
    }
}
