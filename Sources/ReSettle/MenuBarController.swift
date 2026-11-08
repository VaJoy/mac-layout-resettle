import AppKit
import SwiftUI
import Carbon.HIToolbox

final class MenuBarController: NSObject, NSMenuDelegate {
    static weak var shared: MenuBarController?

    private let engine: Engine
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var hotKey: GlobalHotKey?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var lastMessage: String?

    init(engine: Engine) {
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "ReSettle")
                ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "ReSettle")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "ReSettle"
        }

        menu.delegate = self
        statusItem.menu = menu
        MenuBarController.shared = self

        engine.onStatusChange = { [weak self] text, _ in
            self?.statusItem.button?.toolTip = text
            self?.lastMessage = nil
        }
        engine.onRestored = { [weak self] count in
            self?.flash("Restored \(count) windows")
        }

        hotKey = GlobalHotKey(keyCode: HotKeyCombo.remember.keyCode,
                              modifiers: HotKeyCombo.remember.modifiers) { [weak self] in
            self?.engine.rememberNow()
            self?.flash("Layout remembered")
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let trusted = AX.isTrusted

        // 状态行
        let status = NSMenuItem(title: lastMessage ?? engine.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // 权限提示（放最前面，因为是硬门槛）
        if !trusted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            menu.addItem(.separator())
        }

        add("Remember This Layout", #selector(remember), key: "l",
            mods: [.control, .option, .command])
        add("Restore Now", #selector(restoreNow), key: "r",
            mods: [.control, .option, .command])
        add("Undo Last Resettle", #selector(undo), key: "")

        menu.addItem(.separator())

        // This Setup Is…
        let setupItem = NSMenuItem(title: "This Setup Is…", action: nil, keyEquivalent: "")
        let setupMenu = NSMenu()
        let currentName = engine.store.profile(currentKey())?.name
        for preset in ["Home", "Office", "Studio", "MacBook Only"] {
            let item = NSMenuItem(title: preset, action: #selector(pickPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = (currentName == preset) ? .on : .off
            setupMenu.addItem(item)
        }
        setupMenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(pickCustom), keyEquivalent: "")
        custom.target = self
        setupMenu.addItem(custom)
        setupMenu.addItem(.separator())
        let forget = NSMenuItem(title: "Forget This Setup", action: #selector(forget), keyEquivalent: "")
        forget.target = self
        setupMenu.addItem(forget)
        setupItem.submenu = setupMenu
        menu.addItem(setupItem)

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Auto-Restore", action: #selector(toggleAutoRestore), keyEquivalent: "")
        auto.target = self
        auto.state = engine.store.settings.autoRestore ? .on : .off
        menu.addItem(auto)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        add("Settings…", #selector(openSettings), key: ",", mods: [.command])
        add("Quit ReSettle", #selector(quit), key: "q", mods: [.command])
    }

    private func add(_ title: String, _ action: Selector, key: String,
                     mods: NSEvent.ModifierFlags = []) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = mods }
        menu.addItem(item)
    }

    private func currentKey() -> String {
        DisplayManager.setupKey(DisplayManager.snapshot())
    }

    // MARK: - 动作

    @objc private func remember() {
        engine.rememberNow()
        flash("Layout remembered")
    }

    @objc private func restoreNow() {
        engine.restoreNow()
    }

    @objc private func undo() {
        engine.undoLastRestore()
    }

    @objc private func grantAccess() {
        AX.promptIfNeeded()
        AX.openAccessibilitySettings()
        flash("Enable ReSettle in Accessibility")
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, !name.isEmpty else { return }
        engine.renameCurrentSetup(name)
    }

    @objc private func pickCustom() {
        let alert = NSAlert()
        alert.messageText = "Name this setup"
        alert.informativeText = "A name makes the menu easier to read. It does not affect behaviour."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = engine.store.profile(currentKey())?.name ?? ""
        field.placeholderString = "Home"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { engine.renameCurrentSetup(name) }
        }
    }

    @objc private func forget() {
        let alert = NSAlert()
        alert.messageText = "Forget this setup?"
        alert.informativeText = "ReSettle will stop restoring windows for the current display combination."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            engine.forgetCurrentSetup()
        }
    }

    @objc private func toggleAutoRestore() {
        LayoutStore.shared.mutateSettings { $0.autoRestore.toggle() }
    }

    @objc private func toggleLogin() {
        let target = !LoginItem.isEnabled
        if let error = LoginItem.set(target) {
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = error + "\n\nTip: move ReSettle.app into /Applications first."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel()
            settingsModel = model
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "ReSettle"
            window.contentView = hosting
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsModel?.reload()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 自检：把菜单真实结构导出来

    /// 不靠“看代码觉得对”：直接按菜单打开时的逻辑重建一遍，逐项检查
    /// selector 是否存在、target 是否响应、是否会被禁用。
    func debugMenuReport() -> String {
        rebuild()
        var out = "Status menu\n"
        out += String(format: "  icon image      : %@\n", statusItem.button?.image == nil ? "MISSING" : "ok")
        out += String(format: "  icon visible    : %@\n", (statusItem.button?.isHidden ?? true) ? "no" : "yes")

        func walk(_ menu: NSMenu, _ indent: String) {
            for item in menu.items {
                if item.isSeparatorItem { continue }
                let title = item.title
                guard let action = item.action else {
                    out += "\(indent)• \(title)   [no action → disabled label]\n"
                    if let sub = item.submenu { walk(sub, indent + "    ") }
                    continue
                }
                let selector = NSStringFromSelector(action)
                let target = item.target
                let responds = (target as? NSObject)?.responds(to: action) ?? false
                out += "\(indent)• \(title)\n"
                out += "\(indent)    action  : \(selector)\n"
                out += "\(indent)    target  : \(target.map { String(describing: type(of: $0)) } ?? "nil (responder chain)")\n"
                if item.submenu != nil {
                    // 父项由 AppKit 合成 submenuAction:，点它会展开子菜单，属于正常
                    out += "\(indent)    kind    : submenu container\n"
                } else {
                    out += "\(indent)    callable: \(responds ? "yes" : "NO ← 这一项点了会没反应")\n"
                }
                if !item.keyEquivalent.isEmpty {
                    out += "\(indent)    shortcut: \(modifiers(item.keyEquivalentModifierMask))\(item.keyEquivalent)\n"
                }
                if let sub = item.submenu { walk(sub, indent + "    ") }
            }
        }

        walk(menu, "  ")
        return out
    }

    private func modifiers(_ mask: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mask.contains(.control) { s += "⌃" }
        if mask.contains(.option) { s += "⌥" }
        if mask.contains(.shift) { s += "⇧" }
        if mask.contains(.command) { s += "⌘" }
        return s
    }

    /// 真的走一遍菜单项的动作（和点击时走的是同一条 sendAction 路径）
    func debugPerformMenuAction(_ title: String) -> String {
        rebuild()
        guard let item = findItem(titled: title, in: menu) else { return "✗ 找不到菜单项: \(title)" }
        guard let action = item.action else { return "✗ 该项没有 action: \(title)" }
        let sent = NSApp.sendAction(action, to: item.target, from: item)
        return "\(sent ? "✓" : "✗") \(title) → sendAction(\(NSStringFromSelector(action))) = \(sent)"
    }

    private func findItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let hit = findItem(titled: title, in: sub) { return hit }
        }
        return nil
    }

    func debugSettingsWindowVisible() -> Bool {
        settingsWindow?.isVisible ?? false
    }

    /// 逐个走一遍菜单动作，写入 menu.txt。用 sendAction 走的是和真实点击完全相同的路径。
    func runSmokeTest() -> String {
        var out = "Menu action smoke test\n"
        out += "────────────────────────────────────────\n"

        out += debugPerformMenuAction("Remember This Layout") + "\n"
        usleep(2_800_000)

        out += debugPerformMenuAction("Restore Now") + "\n"
        usleep(4_000_000)

        out += debugPerformMenuAction("Undo Last Resettle") + "\n"
        usleep(2_000_000)

        let before = LayoutStore.shared.settings.autoRestore
        out += debugPerformMenuAction("Auto-Restore") + "\n"
        let mid = LayoutStore.shared.settings.autoRestore
        out += debugPerformMenuAction("Auto-Restore") + "\n"
        let after = LayoutStore.shared.settings.autoRestore
        out += "  autoRestore: \(before) → \(mid) → \(after)  \(before == after && before != mid ? "✓ 开关可用" : "✗ 状态没变")\n"

        out += debugPerformMenuAction("Settings…") + "\n"
        usleep(1_800_000)
        out += "  settings window visible: \(debugSettingsWindowVisible() ? "yes ✓" : "NO ✗")\n"

        out += "\n"
        out += debugMenuReport()
        return out
    }

    func writeSmokeTest() {
        let text = runSmokeTest()
        Paths.ensureSupportDir()
        try? text.write(to: Paths.supportDir.appendingPathComponent("menu.txt"),
                        atomically: true, encoding: .utf8)
        Log.info("menu smoke test finished")
    }

    // MARK: - 短暂提示

    private func flash(_ message: String) {
        lastMessage = message
        statusItem.button?.toolTip = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.lastMessage == message else { return }
            self.lastMessage = nil
            self.statusItem.button?.toolTip = self.engine.statusText
        }
    }
}
