import Foundation
import CoreGraphics

/// 用一个朴素结构体存矩形，JSON 更可读、也避免 CG 类型序列化的坑。
struct Rect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height)
    }

    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Size: Codable, Equatable {
    var w: Double
    var h: Double

    init(w: Double, h: Double) { self.w = w; self.h = h }
    init(_ s: CGSize) { self.init(w: s.width, h: s.height) }
    var cg: CGSize { CGSize(width: w, height: h) }
}

/// 单个窗口的“记忆”。
/// `localFrame` 是相对它所在显示器左上角的偏移，这样同一块屏换了分辨率也能按比例还原。
struct WindowRecord: Codable, Equatable {
    var number: Int?          // AXWindowNumber（私有属性，能拿到就用它做最强身份匹配）
    var title: String
    var subrole: String
    var fullscreen: Bool
    var minimized: Bool
    var localFrame: Rect
    var displayKey: String
    var displaySize: Size
    var order: Int
}

struct AppRecord: Codable, Equatable {
    var bundleID: String
    var name: String
    var windows: [WindowRecord]
}

/// 一个“桌面组合”（几块屏的一组）对应一份记忆。
struct Profile: Codable, Equatable {
    var id: String
    var name: String
    var displayNames: [String]
    var displayKeys: [String]
    var apps: [AppRecord]
    var updatedAt: Date

    var windowCount: Int { apps.reduce(0) { $0 + $1.windows.count } }
}

struct Settings: Codable, Equatable {
    var autoRestore: Bool = true
    var autoRecord: Bool = true
    /// 唤醒后至少等这么久才介入。默认 4s —— macOS 重建桌面空间通常要几秒，
    /// 抢在它前面动手不但白费，还可能把半成品布局记成新基线。
    var restoreDelay: Double = 4.0
    var launchAtLogin: Bool = false
    var ignoredBundleIDs: [String] = []
}

/// 磁盘上的完整状态
struct StoredState: Codable {
    var version: Int = 2
    var settings: Settings = Settings()
    var profiles: [String: Profile] = [:]
    var lastSetupKey: String?
}

/// 系统里当前的一块显示器
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let key: String          // 稳定身份（EDID/UUID，重名时按位置加序号）
    let name: String
    let bounds: CGRect       // CG 全局坐标，左上角原点，单位是“点”
    let isMain: Bool
    let isBuiltin: Bool
    let asleep: Bool
}

enum DisplayState: String {
    case settled = "Settled"
    case watching = "Watching"
    case restoring = "Restoring"
    case asleep = "Screen off"
    case noPermission = "No access"
}
