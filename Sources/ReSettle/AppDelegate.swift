import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var lockFD: Int32 = -1
    private var signalSource: DispatchSourceSignal?
    private var selfTestSource: DispatchSourceSignal?
    private var simulationSource: DispatchSourceSignal?
    private var menuTestSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstance() else {
            Log.info("another instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }

        if !AX.isTrusted {
            Log.info("accessibility not granted — prompting")
            AX.promptIfNeeded()
        }

        // 显示器名字来自 NSScreen（主线程），变化时刷新缓存供后台引擎读取
        DisplayManager.refreshNames()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            DisplayManager.refreshNames()
        }

        Engine.shared.start()
        menuBar = MenuBarController(engine: Engine.shared)

        installSignalDump()
    }

    /// kill -USR1 <pid> → 把诊断写进 ~/Library/Application Support/ReSettle/dump.txt
    /// kill -USR2 <pid> → 跑一次“挪开再放回”的端到端自检，结果写进 selftest.txt
    private func installSignalDump() {
        signal(SIGUSR1, SIG_IGN)
        let dumpSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dumpSource.setEventHandler {
            Log.info("SIGUSR1 — writing diagnostics dump")
            Diagnostics.writeToFile()
        }
        dumpSource.resume()
        signalSource = dumpSource

        signal(SIGUSR2, SIG_IGN)
        let testSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        testSource.setEventHandler {
            Log.info("SIGUSR2 — running restore self-test")
            Engine.shared.suspendRecording(seconds: 20)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
                SelfTest.writeToFile()
            }
        }
        testSource.resume()
        selfTestSource = testSource

        // kill -WINCH <pid> → 模拟“唤醒 + macOS 重建桌面”，检验会不会跟系统抢窗口
        signal(SIGWINCH, SIG_IGN)
        let simSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        simSource.setEventHandler {
            Log.info("SIGWINCH — running wake simulation")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                SelfTest.writeSimulationToFile()
            }
        }
        simSource.resume()
        simulationSource = simSource

        // kill -ALRM <pid> → 逐个走一遍菜单动作，结果写 menu.txt
        signal(SIGALRM, SIG_IGN)
        let menuSource = DispatchSource.makeSignalSource(signal: SIGALRM, queue: .main)
        menuSource.setEventHandler {
            Log.info("SIGALRM — menu smoke test")
            MenuBarController.shared?.writeSmokeTest()
        }
        menuSource.resume()
        menuTestSource = menuSource
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.stop()
        if lockFD >= 0 { close(lockFD) }
    }

    /// 用 flock 防止开两份（两份会互相打架）
    private func acquireSingleInstance() -> Bool {
        Paths.ensureSupportDir()
        let fd = open(Paths.lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }
        close(fd)
        return false
    }
}
