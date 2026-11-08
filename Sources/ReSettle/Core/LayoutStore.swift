import Foundation

/// 布局的持久化。全量 JSON，原子写入，节流。
/// 内部用一把锁保护 state，因为引擎在后台队列读写、设置面板在主线程读写。
final class LayoutStore {
    static let shared = LayoutStore()

    private let lock = NSLock()
    private var _state = StoredState()

    private let ioQueue = DispatchQueue(label: "com.vajoylan.resettle.store")
    private var dirty = false
    private var flushScheduled = false

    private init() {
        load()
    }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 访问

    var settings: Settings {
        get { sync { _state.settings } }
        set {
            let changed: Bool = sync {
                guard _state.settings != newValue else { return false }
                _state.settings = newValue
                return true
            }
            if changed { markDirty() }
        }
    }

    var profiles: [String: Profile] { sync { _state.profiles } }

    func profile(_ key: String) -> Profile? { sync { _state.profiles[key] } }

    var lastSetupKey: String? { sync { _state.lastSetupKey } }

    // MARK: - 磁盘

    private func load() {
        Paths.ensureSupportDir()
        guard let data = try? Data(contentsOf: Paths.stateURL),
              var decoded = try? JSON.decoder().decode(StoredState.self, from: data) else {
            Log.info("no existing state, starting fresh")
            return
        }

        // v1 → v2：等待时间从 1.6s 提到 4s（实测 1.6s 会抢在 macOS 重建桌面之前动手）
        if decoded.version < 2 {
            if abs(decoded.settings.restoreDelay - 1.6) < 0.01 {
                decoded.settings.restoreDelay = 4.0
            }
            decoded.version = 2
            Log.info("migrated state v1 → v2 (restoreDelay = \(decoded.settings.restoreDelay))")
        }

        _state = decoded
        Log.info("loaded \(decoded.profiles.count) profiles from \(Paths.stateURL.path)")
        if decoded.version > 1 { markDirty() }
    }

    func markDirty() {
        sync {
            dirty = true
            guard !flushScheduled else { return }
            flushScheduled = true
        }
        ioQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.flush()
        }
    }

    func flushNow() {
        ioQueue.sync { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        let snapshot: StoredState? = sync {
            flushScheduled = false
            guard dirty else { return nil }
            dirty = false
            return _state
        }
        guard let snapshot else { return }
        do {
            let data = try JSON.encoder().encode(snapshot)
            Paths.ensureSupportDir()
            try data.write(to: Paths.stateURL, options: [.atomic])
        } catch {
            Log.error("failed to save state: \(error.localizedDescription)")
        }
    }

    // MARK: - 变更

    /// 记录一次采样。内容相同时只更新时间戳，不写盘。
    /// 返回是否真的产生了新的记忆。
    @discardableResult
    func upsert(key: String, apps: [AppRecord], displays: [DisplayInfo]) -> Bool {
        let clean = apps.filter { !$0.windows.isEmpty }
        guard !clean.isEmpty else { return false }

        let result: Bool = sync {
            if var existing = _state.profiles[key] {
                if existing.apps == clean {
                    existing.updatedAt = Date()
                    _state.profiles[key] = existing
                    return false
                }
                existing.apps = clean
                existing.updatedAt = Date()
                existing.displayNames = displays.map(\.name)
                existing.displayKeys = displays.map(\.key)
                _state.profiles[key] = existing
                _state.lastSetupKey = key
                return true
            }
            let profile = Profile(
                id: key,
                name: DisplayManager.friendlyName(displays),
                displayNames: displays.map(\.name),
                displayKeys: displays.map(\.key),
                apps: clean,
                updatedAt: Date()
            )
            _state.profiles[key] = profile
            _state.lastSetupKey = key
            return true
        }
        if result { markDirty() }
        return result
    }

    func rename(key: String, to name: String) {
        let ok: Bool = sync {
            guard var p = _state.profiles[key] else { return false }
            p.name = name
            _state.profiles[key] = p
            return true
        }
        if ok { markDirty() }
    }

    func remove(key: String) {
        let ok: Bool = sync {
            guard _state.profiles.removeValue(forKey: key) != nil else { return false }
            if _state.lastSetupKey == key { _state.lastSetupKey = nil }
            return true
        }
        if ok { markDirty() }
    }

    func mutateSettings(_ body: (inout Settings) -> Void) {
        let changed: Bool = sync {
            let old = _state.settings
            body(&_state.settings)
            return _state.settings != old
        }
        if changed { markDirty() }
    }
}
