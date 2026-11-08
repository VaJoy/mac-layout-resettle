import Foundation
import CoreGraphics

enum Geometry {

    /// 把记忆里的相对位置映射到目标显示器上。
    /// 同分辨率 → 原样搬；换了分辨率/缩放 → 按比例缩放，并保证标题栏还留在屏内。
    static func target(for rec: WindowRecord, on display: DisplayInfo) -> CGRect {
        let d = display.bounds
        let sameSize = abs(rec.displaySize.w - d.width) < 1.5 && abs(rec.displaySize.h - d.height) < 1.5

        var rect: CGRect
        if sameSize {
            rect = CGRect(x: d.minX + rec.localFrame.x,
                          y: d.minY + rec.localFrame.y,
                          width: rec.localFrame.w,
                          height: rec.localFrame.h)
        } else {
            let sx = rec.displaySize.w > 1 ? d.width / rec.displaySize.w : 1
            let sy = rec.displaySize.h > 1 ? d.height / rec.displaySize.h : 1
            rect = CGRect(x: d.minX + rec.localFrame.x * sx,
                          y: d.minY + rec.localFrame.y * sy,
                          width: rec.localFrame.w * sx,
                          height: rec.localFrame.h * sy)
        }

        // 尺寸不超过屏幕
        rect.size.width = min(max(rect.width, 120), d.width)
        rect.size.height = min(max(rect.height, 80), d.height)

        // 保证窗口至少有 64pt 落在屏幕里，不会“恢复到看不见的地方”
        let margin: CGFloat = 64
        rect.origin.x = min(max(rect.minX, d.minX - rect.width + margin), d.maxX - margin)
        rect.origin.y = min(max(rect.minY, d.minY), d.maxY - margin)

        return rect.integral
    }

    /// 恢复时的收敛判据：尽量精确（3pt）
    static func needsAdjustment(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) > tolerance
            || abs(a.minY - b.minY) > tolerance
            || abs(a.width - b.width) > tolerance
            || abs(a.height - b.height) > tolerance
    }

    /// 判断“这个窗口算不算被系统搞乱了”。
    /// 位置要严格（8pt）；尺寸放宽到 48pt ——
    /// 有些 App（尤其被"最大化"过的窗口）会自己把高度改几像素，
    /// 那不是乱，不能因此触发一次全量搬动。
    static func isBadlyOff(_ current: CGRect, _ target: CGRect) -> Bool {
        if abs(current.minX - target.minX) > 8 || abs(current.minY - target.minY) > 8 { return true }
        if abs(current.width - target.width) > 48 || abs(current.height - target.height) > 48 { return true }
        return false
    }
}
