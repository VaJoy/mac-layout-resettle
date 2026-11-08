import Foundation
import AppKit
import CoreGraphics

/// 把当前所有 App 的窗口读成一组 AppRecord。
enum WindowSampler {

    /// 这些进程永远不该被记忆（菜单栏、Dock、系统 UI 等）
    static let blocked: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.controlcenter.agent",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.universalcontrol",
        "com.apple.ScreenSaver.Engine",
        "com.apple.CoreServicesUIAgent",
        "com.apple.talagent"
    ]

    static let allowedSubroles: Set<String> = [
        "AXStandardWindow", "AXDialog", "AXFloatingWindow", "AXSystemDialog", ""
    ]

    static func sample(displays: [DisplayInfo], ignored: [String] = []) -> [AppRecord] {
        guard AX.isTrusted else { return [] }
        let ignoredSet = Set(ignored)
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var result: [AppRecord] = []

        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated else { continue }
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            let pid = app.processIdentifier
            guard pid > 0, pid != ownPid else { continue }
            guard app.activationPolicy != .prohibited else { continue }
            if blocked.contains(bundleID) || ignoredSet.contains(bundleID) { continue }

            let axApp = AXUIElementCreateApplication(pid)
            guard let windows = AX.elements(axApp, kAXWindowsAttribute), !windows.isEmpty else { continue }

            var records: [WindowRecord] = []
            for (index, win) in windows.prefix(40).enumerated() {
                guard let role = AX.string(win, kAXRoleAttribute), role == "AXWindow" else { continue }
                let subrole = AX.string(win, kAXSubroleAttribute) ?? ""
                guard allowedSubroles.contains(subrole) else { continue }

                // 60pt 以下基本是工具类 App 的贴边手柄/分割线，不值得记
                guard let frame = AX.frame(win), frame.width >= 60, frame.height >= 60 else { continue }
                guard let display = DisplayManager.display(for: frame, in: displays) else { continue }

                let fullscreen = AX.bool(win, "AXFullScreen") ?? false
                let minimized = AX.bool(win, kAXMinimizedAttribute) ?? false
                // 全屏窗口在所有 Space 里都“占满整块屏”，坐标不可靠，单独标记
                let effective = fullscreen ? display.bounds : frame

                records.append(WindowRecord(
                    number: AX.number(win, "AXWindowNumber"),
                    title: AX.string(win, kAXTitleAttribute) ?? "",
                    subrole: subrole,
                    fullscreen: fullscreen,
                    minimized: minimized,
                    localFrame: Rect(x: effective.minX - display.bounds.minX,
                                     y: effective.minY - display.bounds.minY,
                                     w: effective.width,
                                     h: effective.height),
                    displayKey: display.key,
                    displaySize: Size(display.bounds.size),
                    order: index
                ))
            }

            guard !records.isEmpty else { continue }
            result.append(AppRecord(bundleID: bundleID,
                                    name: app.localizedName ?? bundleID,
                                    windows: records))
        }

        result.sort { $0.bundleID < $1.bundleID }
        return result
    }
}
