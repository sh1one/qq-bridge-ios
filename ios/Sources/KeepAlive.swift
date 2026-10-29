import AVFoundation
import UIKit

/// 后台常驻的"呼吸"。
///
/// iOS 不会允许任何 App 真正永久驻留，侧载场景下唯一稳一点的办法是声明
/// `UIBackgroundModes = audio` 并让 AVAudioSession 一直处于活跃播放状态。
/// 这里循环播放一段 1 秒的静音 wav：系统认为你在放音频，就不会因为"空闲"把进程挂起。
///
/// 已知边界（写清楚，别假装能保证）：
/// - 系统内存压力大、低电量模式、用户手动上滑，仍然会被杀；
/// - 被系统中断（来电、闹钟、其他 App 抢占音频）后要能自己爬起来，所以有 interruption 观察者 + 看门狗；
/// - App Store 不允许这种用法，只走侧载。
final class KeepAlive {
    private let session = AVAudioSession.sharedInstance()
    private var player: AVAudioPlayer?
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let stateQueue = DispatchQueue(label: "xiaobeiming.keepalive")

    private(set) var running = false
    private var suspended = false

    /// 最近一次保活失败的原因，给设置页和桥接心跳用。
    private(set) var lastError: String = ""

    func start() {
        if running { return }
        running = true
        suspended = false
        installObservers()
        startWatchdog()
        activateAndPlay()
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        stateQueue.async { [weak self] in
            self?.player?.stop()
            self?.player = nil
        }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        removeObservers()
    }

    /// 录音时让出音频会话（AVAudioSession 的 category 是全局的，不能同时 playback 和 record）。
    func suspendForRecording() {
        suspended = true
        player?.pause()
    }

    /// 录完恢复播放并重新占住会话。
    func resumeAfterRecording() {
        guard running else { return }
        suspended = false
        activateAndPlay()
    }

    // MARK: - 播放

    private func activateAndPlay() {
        guard running, !suspended else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            lastError = ""
        } catch {
            lastError = "音频会话激活失败：\(error.localizedDescription)"
            return
        }
        if player == nil {
            guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
                lastError = "资源 silence.wav 缺失，保活无法启动"
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1          // 无限循环，永远"正在播放"
                p.volume = 0.0
                p.prepareToPlay()
                player = p
            } catch {
                lastError = "静音音频初始化失败：\(error.localizedDescription)"
                return
            }
        }
        guard let p = player else { return }
        if !p.isPlaying {
            p.play()
        }
    }

    private func restartSoon(after seconds: Double) {
        guard running, !suspended else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.running, !self.suspended else { return }
            self.activateAndPlay()
        }
    }

    // MARK: - 看门狗

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: stateQueue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.running, !self.suspended else { return }
            if self.player?.isPlaying != true {
                self.restartSoon(after: 0.2)
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: - 系统事件

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                           object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.restartSoon(after: 0.5)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.stateQueue.async {
                self.player = nil
            }
            self.restartSoon(after: 1.0)
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.restartSoon(after: 0.2)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.restartSoon(after: 0.2)
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            player?.pause()
        case .ended:
            let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            let delay = options.contains(.shouldResume) ? 0.4 : 1.5
            restartSoon(after: delay)
        @unknown default:
            restartSoon(after: 1.0)
        }
    }
}
