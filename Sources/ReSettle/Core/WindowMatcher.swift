import Foundation
import ApplicationServices
import CoreGraphics

/// 把“记忆里的窗口”和“现在真实存在的窗口”配对。
///
/// 顺序很重要：窗口号 → 标题 → 位置就近 → 数组顺序。
/// 窗口号在同一次登录会话里是稳定的，最可靠；但有些 App（尤其是自己画浮层的工具）
/// 每次枚举出来的顺序都会变、标题还是空的，这时“位置就近”比“数组顺序”准得多。
enum WindowMatcher {

    static func match(_ records: [WindowRecord],
                      _ windows: [AXUIElement],
                      expected: ((WindowRecord) -> CGRect?)? = nil) -> [(WindowRecord, AXUIElement)] {

        var used = Set<Int>()
        var result: [(WindowRecord, AXUIElement)] = []
        var pending: [WindowRecord] = []

        // 1) 窗口号
        var numbers: [Int: Int] = [:]   // windowNumber -> index
        for (i, w) in windows.enumerated() {
            if let n = AX.number(w, "AXWindowNumber"), numbers[n] == nil {
                numbers[n] = i
            }
        }
        for rec in records {
            if let n = rec.number, let idx = numbers[n], !used.contains(idx) {
                used.insert(idx)
                result.append((rec, windows[idx]))
            } else {
                pending.append(rec)
            }
        }

        // 2) 标题（同 App 内标题基本唯一；空标题不参与）
        var leftover: [WindowRecord] = []
        var titles: [(Int, String)] = []
        for (i, w) in windows.enumerated() where !used.contains(i) {
            if let t = AX.string(w, kAXTitleAttribute), !t.isEmpty { titles.append((i, t)) }
        }
        for rec in pending {
            if !rec.title.isEmpty, let hit = titles.first(where: { $0.1 == rec.title && !used.contains($0.0) }) {
                used.insert(hit.0)
                result.append((rec, windows[hit.0]))
            } else {
                leftover.append(rec)
            }
        }

        // 3) 位置就近：全局贪心，避免“一对一按顺序”配反
        if let expected, !leftover.isEmpty {
            var pairs: [(recordIndex: Int, windowIndex: Int, distance: CGFloat)] = []
            for (ri, rec) in leftover.enumerated() {
                guard let want = expected(rec) else { continue }
                for (wi, w) in windows.enumerated() where !used.contains(wi) {
                    guard let frame = AX.frame(w) else { continue }
                    pairs.append((ri, wi, distance(frame, want)))
                }
            }
            pairs.sort { $0.distance < $1.distance }

            var matchedRecords = Set<Int>()
            for p in pairs where !matchedRecords.contains(p.recordIndex) && !used.contains(p.windowIndex) {
                matchedRecords.insert(p.recordIndex)
                used.insert(p.windowIndex)
                result.append((leftover[p.recordIndex], windows[p.windowIndex]))
            }
            leftover = leftover.enumerated()
                .filter { !matchedRecords.contains($0.offset) }
                .map { $0.element }
        }

        // 4) 顺序兜底
        let remaining = windows.indices.filter { !used.contains($0) }
        for (rec, idx) in zip(leftover, remaining) {
            result.append((rec, windows[idx]))
        }

        return result
    }

    /// 位置误差 + 半个尺寸误差，够用来区分“同一 App 的两个窗口”
    private static func distance(_ frame: CGRect, _ target: CGRect) -> CGFloat {
        abs(frame.minX - target.minX)
            + abs(frame.minY - target.minY)
            + abs(frame.width - target.width) * 0.5
            + abs(frame.height - target.height) * 0.5
    }
}
