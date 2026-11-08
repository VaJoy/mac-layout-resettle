import AppKit

/// `ReSettle --dump`：把当前状态打到终端，方便验证“我到底记住了什么”。
/// 另外支持给运行中的 App 发 SIGUSR1，把同样的内容写进 dump.txt
/// （终端里跑 binary 时，TCC 可能把授权归到“责任进程”而不是 App 本身，
///   所以进程内自取一份才准）。
enum Diagnostics {

    static func run() {
        _ = NSApplication.shared   // 让 AppKit 起来，NSScreen 才有内容
        DisplayManager.refreshNames()
        print(capture())
    }

    static func writeToFile() {
        let text = capture()
        Paths.ensureSupportDir()
        try? text.write(to: Paths.supportDir.appendingPathComponent("dump.txt"),
                        atomically: true, encoding: .utf8)
    }

    static func capture() -> String {
        var out = ""
        func line(_ s: String) { out += s + "\n" }

        line("ReSettle diagnostics")
        line("────────────────────────────────────────")
        line("time             : \(ISO8601DateFormatter.local.string(from: Date()))")
        line("macOS            : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("Accessibility    : \(AX.isTrusted ? "granted" : "NOT granted")")
        line("State file       : \(Paths.stateURL.path)")
        line("")

        let displays = DisplayManager.snapshot()
        let key = DisplayManager.setupKey(displays)
        line("Displays (\(displays.count)) — setup \(key)")
        for d in displays {
            let b = d.bounds
            line(String(format: "  • %-22@ key=%@  %4.0fx%-4.0f @ (%.0f,%.0f)%@%@",
                        d.name as NSString, d.key as NSString,
                        b.width, b.height, b.minX, b.minY,
                        d.isMain ? "  [main]" : "",
                        d.asleep ? "  [asleep]" : ""))
        }
        line("")

        let store = LayoutStore.shared
        let profiles = store.profiles

        let containers = TabGroupsBridge.containerRects()
        if containers.isEmpty {
            line("TabGroups        : not running / no containers")
        } else {
            line("TabGroups        : \(containers.count) container(s) — their panes are left to TabGroups")
            for c in containers {
                line(String(format: "  ▢ [%.0f,%.0f %.0fx%.0f]", c.minX, c.minY, c.width, c.height))
            }
        }
        line("")
        line("Profiles (\(profiles.count))")
        for (id, p) in profiles.sorted(by: { $0.value.updatedAt > $1.value.updatedAt }) {
            let mark = id == key ? "  ← current" : ""
            line("  • \(p.name) [\(id)]  \(p.windowCount) windows  \(p.displayNames.joined(separator: " + "))\(mark)")
        }
        line("")

        if let current = store.profile(key) {
            line("Remembered windows for current setup:")
            out += describe(current.apps)
            if AX.isTrusted {
                let needs = LayoutDeviation.needsRestore(profile: current, displays: displays)
                line("layout vs memory : \(needs ? "DIFFERENT — would restore" : "matches")")
            }
            line("")
        }

        guard AX.isTrusted else {
            line("(live window list needs Accessibility permission)")
            return out
        }
        let live = WindowSampler.sample(displays: displays)
        line("Live windows (\(live.reduce(0) { $0 + $1.windows.count })):")
        out += describe(live)

        out += "\n"
        out += "Login at startup  : \(LoginItem.statusDescription)\n"
        out += "\n"
        out += MenuBarController.shared?.debugMenuReport() ?? "Menu: controller not available\n"
        return out
    }

    private static func describe(_ apps: [AppRecord]) -> String {
        var out = ""
        for app in apps {
            out += "  \(app.name) (\(app.bundleID))\n"
            for w in app.windows {
                let f = w.localFrame
                out += String(format: "      %@  [%.0f,%.0f %.0fx%.0f] on %@%@\n",
                              (w.title.isEmpty ? "(untitled)" : w.title) as NSString,
                              f.x, f.y, f.w, f.h,
                              w.displayKey as NSString,
                              w.fullscreen ? "  fullscreen" : "")
            }
        }
        return out
    }
}
