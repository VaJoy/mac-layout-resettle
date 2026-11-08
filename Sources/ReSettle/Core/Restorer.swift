import Foundation
import AppKit

struct RestoreOutcome {
    let app: String
    let title: String
    let requested: CGRect
    let before: CGRect
    let after: CGRect
    let fullscreen: Bool

    var converged: Bool {
        fullscreen || !Geometry.needsAdjustment(after, requested)
    }
}

/// 真正搬窗口的地方。
enum Restorer {

    /// - Parameter onlyDeviating: 只处理还没到位的窗口。第二轮回补时用，
    ///   免得已经摆好的窗口被再挪一次（用户会看到不必要的抖动）。
    @discardableResult
    static func apply(profile: Profile, displays: [DisplayInfo], onlyDeviating: Bool = false) -> [RestoreOutcome] {
        guard AX.isTrusted else { return [] }
        var outcomes: [RestoreOutcome] = []

        // TabGroups 的容器壳先放回去：它一移动就会把窗格重排好，
        // 之后我们再写窗格坐标时已经是同一个位置，不会触发它的回弹。
        let ordered = profile.apps.sorted { a, b in
            let at = a.bundleID == TabGroupsBridge.bundleID
            let bt = b.bundleID == TabGroupsBridge.bundleID
            if at != bt { return at }
            return a.bundleID < b.bundleID
        }

        for app in ordered {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .first(where: { !$0.isTerminated }) else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            guard let windows = AX.elements(axApp, kAXWindowsAttribute), !windows.isEmpty else { continue }

            for (rec, win) in WindowMatcher.match(app.windows, windows,
                                                  expected: LayoutDeviation.expectedTarget(displays)) {
                guard let display = displays.first(where: { $0.key == rec.displayKey }) else { continue }
                if (AX.bool(win, kAXMinimizedAttribute) ?? false) { continue }

                let target = Geometry.target(for: rec, on: display)
                let before = AX.frame(win) ?? .zero
                let wasFullscreen = AX.bool(win, "AXFullScreen") ?? false

                // 第二轮：已经到位的窗口不要再碰
                if onlyDeviating, !rec.fullscreen, !Geometry.isBadlyOff(before, target) { continue }

                // 全屏窗口住在自己的 Space 里，必须先退出来才能搬
                if wasFullscreen {
                    AX.raise(win)
                    AX.set(win, "AXFullScreen", false)
                    usleep(650_000)
                }

                let after = applyConverging(win, to: target)

                // 如果记忆里它是全屏，回到记忆里的那块屏之后再进全屏
                if rec.fullscreen, !(AX.bool(win, "AXFullScreen") ?? false) {
                    AX.raise(win)
                    if AX.set(win, "AXFullScreen", true) {
                        usleep(550_000)
                    }
                }

                outcomes.append(RestoreOutcome(app: app.name,
                                                title: rec.title,
                                                requested: target,
                                                before: before,
                                                after: after,
                                                fullscreen: rec.fullscreen))
                usleep(10_000)
            }

            // 给 TabGroups 一点时间把窗格排完，再去处理其它窗口
            if app.bundleID == TabGroupsBridge.bundleID {
                usleep(280_000)
            }
        }

        return outcomes
    }

    /// 设一次不一定成：有的 App 会因为“当时的窗口状态/最小尺寸/贴边吸附”把值改掉。
    /// 所以设完读回来核对，不对再补一次，最多 3 轮。
    @discardableResult
    static func applyConverging(_ win: AXUIElement, to target: CGRect, attempts: Int = 3) -> CGRect {
        var current = target
        for attempt in 0..<attempts {
            AX.setFrame(win, target)
            usleep(35_000)
            guard let now = AX.frame(win) else { continue }
            current = now
            if !Geometry.needsAdjustment(now, target) { return now }
            if attempt == attempts - 1 { break }
            // 第二轮先轻微错开一下，绕过“值没变就不重算布局”的 App
            if attempt == 1 {
                AX.set(win, kAXSizeAttribute, CGSize(width: target.width, height: max(target.height - 2, 80)))
                usleep(25_000)
            }
        }
        return current
    }
}
