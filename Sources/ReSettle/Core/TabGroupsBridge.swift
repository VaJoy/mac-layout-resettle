import Foundation
import AppKit
import CoreGraphics

/// 与 TabGroups（窗口合并/拼贴工具）协作。
///
/// TabGroups 的模型：一个 NSPanel 当「壳」，其他 App 的窗口被 AX 塞进壳里当「窗格」。
/// 关键事实（来自它的源码 `Container.swift`）：
///   - `containerWindowFrameChanged` → `frame = newFrame; layout()`
///     **壳一移动，它立刻把所有窗格重排到新位置**。
///   - `handleChildEvent(.moved)` → 0.15s 后把窗格拽回它算出来的位置。
///
/// 所以策略是「先搬壳、后搬窗格」，而不是「完全不管窗格」：
///   1. 先把容器壳放回原处 → TabGroups 的 `layout()` 会自动把窗格排好；
///   2. 再处理普通窗口。这时窗格已经在正确位置，我们写同样的坐标，
///      TabGroups 的 `!current.equalTo(rect)` 判断为 false，不会触发回弹。
///
/// 反面做法（用「窗口是否被容器矩形包住」来排除窗格）不可行：
/// 一块几乎铺满屏幕的容器，会把背后所有普通窗口都算成窗格，误伤一大片。
enum TabGroupsBridge {
    static let bundleID = "tech.ripplex.tabgroups"

    /// 容器壳的最小高度。分割线/缩放手柄都是 3~58pt 的细条。
    static let minShellHeight: CGFloat = 200

    /// 当前所有容器壳的矩形（AX 全局坐标）
    static func containerRects() -> [CGRect] {
        guard AX.isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }) else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = AX.elements(axApp, kAXWindowsAttribute) else { return [] }

        var rects: [CGRect] = []
        for w in windows {
            guard let f = AX.frame(w) else { continue }
            guard f.height >= minShellHeight, f.width >= 300 else { continue }
            rects.append(f)
        }
        return rects
    }

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.isEmpty
    }
}
