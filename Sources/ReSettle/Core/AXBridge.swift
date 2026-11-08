import Foundation
import ApplicationServices
import AppKit

/// Accessibility API 的薄封装。所有跨 App 的窗口读写都走这里。
enum AX {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptIfNeeded() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 读

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        return err == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func number(_ el: AXUIElement, _ name: String) -> Int? {
        guard let v = attr(el, name) else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        guard let v = attr(el, name) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement]? {
        guard let v = attr(el, name), CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        let array = v as! CFArray
        var out: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(array) {
            let raw = CFArrayGetValueAtIndex(array, i)
            let obj = unsafeBitCast(raw, to: CFTypeRef.self)
            if CFGetTypeID(obj) == AXUIElementGetTypeID() {
                out.append(unsafeBitCast(obj, to: AXUIElement.self))
            }
        }
        return out
    }

    static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: - 写

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ p: CGPoint) -> Bool {
        var p = p
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ s: CGSize) -> Bool {
        var s = s
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ b: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, (b ? kCFBooleanTrue : kCFBooleanFalse)) == .success
    }

    /// 位置 → 尺寸 → 位置，抵抗某些 App 的“先设尺寸会把窗口推走”行为。
    @discardableResult
    static func setFrame(_ el: AXUIElement, _ rect: CGRect) -> Bool {
        var ok = false
        if set(el, kAXPositionAttribute, rect.origin) { ok = true }
        usleep(4_000)
        if set(el, kAXSizeAttribute, rect.size) { ok = true }
        usleep(4_000)
        _ = set(el, kAXPositionAttribute, rect.origin)
        return ok
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }
}
