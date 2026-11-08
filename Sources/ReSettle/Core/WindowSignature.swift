import Foundation
import CoreGraphics

/// 廉价的“窗口有没有动过”指纹。
/// 只调用一次 CGWindowListCopyWindowInfo（进程内、纳秒级），避免每秒都去戳一堆 App 的 AX 接口。
enum WindowSignature {

    struct Entry {
        let pid: pid_t
        let number: Int
        let bounds: CGRect
    }

    static func entries() -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [Entry] = []
        out.reserveCapacity(list.count)
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let dict = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let number = (w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            let x = (dict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (dict["Y"] as? NSNumber)?.doubleValue ?? 0
            let wd = (dict["Width"] as? NSNumber)?.doubleValue ?? 0
            let ht = (dict["Height"] as? NSNumber)?.doubleValue ?? 0
            guard wd > 1, ht > 1 else { continue }
            out.append(Entry(pid: pid, number: number,
                             bounds: CGRect(x: x, y: y, width: wd, height: ht)))
        }
        return out
    }

    static func current() -> String {
        let list = entries()
        guard !list.isEmpty else { return "empty" }
        var parts: [String] = []
        parts.reserveCapacity(list.count)
        for e in list.sorted(by: { $0.number < $1.number }) {
            parts.append("\(e.pid).\(e.number):\(Int(e.bounds.minX)),\(Int(e.bounds.minY)),\(Int(e.bounds.width)),\(Int(e.bounds.height))")
        }
        return parts.joined(separator: "|")
    }
}
