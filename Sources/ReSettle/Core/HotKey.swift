import Foundation
import Carbon.HIToolbox
import AppKit

/// 全局快捷键，用 Carbon 的 RegisterEventHotKey。
/// 好处：不需要额外权限，App 在后台也能触发。
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x5253_5453 // 'RSTS'

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.actions[id] = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            guard err == noErr else { return OSStatus(eventNotHandledErr) }
            if let action = GlobalHotKey.actions[hkID.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        guard status == noErr else { return nil }

        let hkID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hkID,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr else { return nil }
        Log.info("registered global hotkey \(keyCode) mods \(modifiers)")
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        GlobalHotKey.actions.removeValue(forKey: id)
    }
}

/// 常用组合：⌃⌥⌘ + 字母
enum HotKeyCombo {
    static let remember = (keyCode: UInt32(kVK_ANSI_L),
                           modifiers: UInt32(controlKey | optionKey | cmdKey))
}
