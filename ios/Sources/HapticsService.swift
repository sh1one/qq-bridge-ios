import CoreHaptics
import UIKit

/// 情绪。四种预设脉冲，全部用 CoreHaptics 现场合成，不依赖任何音频文件。
///
/// 硬限制（如实写在代码里）：CoreHaptics 在 App 进入后台后会停止，
/// 所以"待机时远距离震一下"只有在 App 处于前台、或刚被唤醒的瞬间才有效；
/// 不支持 CoreHaptics 的老设备/模拟器回落到 UIImpactFeedbackGenerator。
final class HapticsService {
    private var engine: CHHapticEngine?
    private(set) var lastError: String = ""
    private(set) var usedFallback = false

    var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    private func ensureEngine() throws -> CHHapticEngine {
        if let e = engine { return e }
        let e = try CHHapticEngine()
        e.playsHapticsOnly = true
        e.isMutedForHaptics = false
        e.stoppedHandler = { [weak self] reason in
            self?.lastError = "触觉引擎停止：\(reason)"
            self?.engine = nil
        }
        e.resetHandler = { [weak self] in
            try? self?.engine?.start()
        }
        try e.start()
        engine = e
        return e
    }

    /// 返回 (是否成功, 是否用了普通震动兜底)
    @discardableResult
    func play(pattern: String, intensity: Double = 0.7) -> (ok: Bool, fallback: Bool) {
        let level = Float(max(0.05, min(1.0, intensity)))
        usedFallback = false
        guard supportsHaptics else {
            usedFallback = true
            return (impactFallback(pattern: pattern), true)
        }
        do {
            let events = try buildEvents(pattern: pattern, intensity: level)
            let patternObj = try CHHapticPattern(events: events, parameters: [])
            let engine = try ensureEngine()
            let player = try engine.makePlayer(with: patternObj)
            try player.start(atTime: 0)
            lastError = ""
            return (true, false)
        } catch {
            lastError = "触觉播放失败：\(error.localizedDescription)"
            usedFallback = true
            return (impactFallback(pattern: pattern), true)
        }
    }

    private func buildEvents(pattern: String, intensity: Float) throws -> [CHHapticEvent] {
        func transient(_ t: TimeInterval, _ i: Float, _ s: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, i))),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, s))),
                          ],
                          relativeTime: t)
        }
        func continuous(_ t: TimeInterval, _ dur: TimeInterval, _ i: Float, _ s: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticContinuous,
                          parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, i))),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, s))),
                          ],
                          relativeTime: t,
                          duration: dur)
        }

        switch pattern.lowercased() {
        case "heartbeat":
            // 咚—咚 … 咚—咚，两拍渐弱，像贴着的心跳。
            return [
                transient(0.00, intensity * 0.90, 0.45),
                transient(0.16, intensity * 0.55, 0.35),
                transient(0.86, intensity * 0.80, 0.45),
                transient(1.02, intensity * 0.45, 0.35),
            ]
        case "shiver":
            // 高频小抖：12 下密集的轻触。
            var out: [CHHapticEvent] = []
            for i in 0..<12 {
                let t = Double(i) * 0.032
                out.append(transient(t, intensity * 0.30, 0.75))
            }
            out.append(continuous(0.0, 0.40, intensity * 0.12, 0.30))
            return out
        case "pulse":
            // 一下重拍：短促continuous + 尾部transient，像心跳漏掉一拍。
            return [
                continuous(0.0, 0.10, intensity, 0.35),
                transient(0.11, intensity * 0.85, 0.55),
            ]
        case "buzz":
            // 连续短震，像手机在嗡嗡地不满。
            var out: [CHHapticEvent] = []
            for i in 0..<5 {
                out.append(transient(Double(i) * 0.12, intensity * 0.75, 0.65))
            }
            return out
        default:
            return [transient(0.0, intensity, 0.5)]
        }
    }

    private func impactFallback(pattern: String) -> Bool {
        switch pattern.lowercased() {
        case "heartbeat":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        case "shiver":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        case "pulse":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return true
        case "buzz":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return true
        default:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        }
    }

    func stop() {
        engine?.stop(completionHandler: nil)
        engine = nil
    }
}
