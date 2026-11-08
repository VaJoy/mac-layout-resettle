import Foundation
import AppKit
import CoreGraphics
import CryptoKit

/// 显示器枚举与身份识别。
///
/// 关键设计：**同一个桌面组合 → 同一个 setupKey**。
/// 这样显示器睡着时窗口被折叠到内屏，折叠后的布局自然落到另一个 key 上，
/// 不会把好好的记忆覆盖成一堆挤在一起的窗口。
enum DisplayManager {

    // 显示器名字只能从 NSScreen 拿，而 NSScreen 属于 AppKit（主线程）。
    // 引擎在后台队列每秒采样，所以这里做一个主线程填、任意线程读的名字缓存，
    // 避免后台碰 AppKit。
    private static let nameLock = NSLock()
    private static var nameCache: [CGDirectDisplayID: String] = [:]

    /// 只能在主线程调用
    static func refreshNames() {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                map[num.uint32Value] = screen.localizedName
            }
        }
        nameLock.lock()
        nameCache = map
        nameLock.unlock()
    }

    private static func cachedName(_ id: CGDirectDisplayID) -> String? {
        nameLock.lock()
        defer { nameLock.unlock() }
        return nameCache[id]
    }

    // MARK: - 枚举

    static func snapshot() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        ids = Array(ids.prefix(Int(count)))

        let mainID = CGMainDisplayID()

        // 先按屏幕位置排序，保证“同型号双屏”的序号稳定（左=1，右=2）
        var bases: [(id: CGDirectDisplayID, base: String, bounds: CGRect)] = ids.map {
            (id: $0, base: fingerprint($0), bounds: CGDisplayBounds($0))
        }
        bases.sort { a, b in
            if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
            if a.bounds.minY != b.bounds.minY { return a.bounds.minY < b.bounds.minY }
            return a.id < b.id
        }

        var ordinal: [String: Int] = [:]
        var result: [DisplayInfo] = []
        for item in bases {
            let n = ordinal[item.base, default: 0]
            ordinal[item.base] = n + 1
            // 有重名才加后缀，单屏保持干净
            let duplicated = bases.filter { $0.base == item.base }.count > 1
            let key = duplicated ? "\(item.base)#\(n)" : item.base

            result.append(DisplayInfo(
                id: item.id,
                key: key,
                name: cachedName(item.id) ?? defaultName(vendor: CGDisplayVendorNumber(item.id),
                                                          model: CGDisplayModelNumber(item.id),
                                                          builtin: CGDisplayIsBuiltin(item.id) != 0),
                bounds: item.bounds,
                isMain: item.id == mainID,
                isBuiltin: CGDisplayIsBuiltin(item.id) != 0,
                asleep: CGDisplayIsAsleep(item.id) != 0
            ))
        }
        // 返回时恢复成“主屏优先”的直觉顺序
        return result.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
            return a.bounds.minY < b.bounds.minY
        }
    }

    private static func defaultName(vendor: UInt32, model: UInt32, builtin: Bool) -> String {
        if builtin { return "Built-in Display" }
        return String(format: "Display %04X:%04X", vendor, model)
    }

    // MARK: - 身份

    /// EDID 派生的 UUID 最稳定；退化为 vendor/model/serial；再退化为几何指纹。
    private static func fingerprint(_ id: CGDirectDisplayID) -> String {
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = unmanaged.takeRetainedValue()
            if let s = CFUUIDCreateString(nil, uuid) as String? {
                return "uuid-" + s
            }
        }
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        if serial != 0 {
            return "edid-\(vendor)-\(model)-\(serial)"
        }
        let b = CGDisplayBounds(id)
        return "geom-\(vendor)-\(model)-\(Int(b.width))x\(Int(b.height))"
    }

    // MARK: - 组合 Key

    static func setupKey(_ displays: [DisplayInfo]) -> String {
        let joined = displays.map(\.key).sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "s" + hex.prefix(12)
    }

    static func display(_ key: String, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.key == key }
    }

    /// 窗口落在哪块屏：取面积交集最大的；完全没交集就取中心点最近的。
    static func display(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        let usable = displays.filter { $0.bounds.width > 1 && $0.bounds.height > 1 }
        guard !usable.isEmpty else { return nil }

        var best: (DisplayInfo, CGFloat)?
        for d in usable {
            let inter = d.bounds.intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > (best?.1 ?? 0) { best = (d, area) }
        }
        if let best, best.1 > 0 { return best.0 }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        return usable.min { a, b in
            distance(center, a.bounds) < distance(center, b.bounds)
        }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    static func friendlyName(_ displays: [DisplayInfo]) -> String {
        if displays.count == 1, let only = displays.first, only.isBuiltin {
            return "MacBook Only"
        }
        return "\(displays.count) Displays"
    }
}
