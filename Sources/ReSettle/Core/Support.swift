import Foundation
import os.log

/// 日志：同时写 os_log 和轮转文件，方便排查（用户看不到 Console 时可直接看文件）。
enum Log {
    private static let logger = Logger(subsystem: "com.vajoylan.resettle", category: "app")
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024

    static var fileURL: URL { Paths.supportDir.appendingPathComponent("resettle.log") }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERR ", message)
    }

    private static func append(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        Paths.ensureSupportDir()

        let stamp = ISO8601DateFormatter.local.string(from: Date())
        let line = "[\(stamp)] \(level) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            // 简单轮转：保留最后 1/4
            if let existing = try? Data(contentsOf: fileURL), existing.count > maxBytes / 4 {
                let tail = existing.suffix(maxBytes / 4)
                try? tail.write(to: fileURL, options: [.atomic])
            } else {
                try? Data().write(to: fileURL)
            }
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

enum Paths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ReSettle", isDirectory: true)
    }()

    static var stateURL: URL { supportDir.appendingPathComponent("state.json") }
    static var lockURL: URL { supportDir.appendingPathComponent("resettle.lock") }

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}

extension ISO8601DateFormatter {
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum JSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
