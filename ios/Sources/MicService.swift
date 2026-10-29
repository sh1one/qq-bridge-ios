import AVFoundation

enum MicError: LocalizedError {
    case permission
    case session(String)
    case recorder(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .permission: return "没有麦克风权限：去 设置 → 小北冥 → 麦克风 打开"
        case .session(let why): return "音频会话配置失败：\(why)"
        case .recorder(let why): return "录音器启动失败：\(why)"
        case .empty: return "录到的文件是空的"
        }
    }
}

struct MicResult {
    let url: URL
    let durationSec: Double
    let rms: Double
    let peak: Double
    let silent: Bool
    /// "vad" = 说完后静音自动收尾；"duration" = 录满上限
    var stoppedBy: String = "duration"
    /// 最后一次检测到人声的时刻（秒，相对录音开始）；没听到人声是 0
    var speechSec: Double = 0
    /// 收尾时已经静音了多久（毫秒）
    var silenceMs: Int = 0
    /// 这次录音的上限（秒）
    var maxSec: Double = 0
}

/// 耳朵。自适应时长录音，16kHz 单声道 16bit PCM，存成 wav。
///
/// 两个指标一起用：
/// 1) 静音检测：实时表 100ms 采样，整段最大 RMS 低于阈值 ⇒ silent=true（不上传空音频）；
/// 2) **说完即停（VAD）**：一旦听到过人声，之后静音超过 silenceMs（默认 800ms）就立刻收尾，
///    不再傻等满 N 秒。端到端「听到出声」的延迟里，录音时长原来是硬编码的
///    6 秒里最贵的一段（6s → 1.5~2s 这一截是白赚的）。
///    没听到任何人声时给 noVoiceGuard（默认 2.5s）兜底，避免一屋子安静也录满 N 秒。
/// seconds 仍然是**上限**：VAD 只提前，不会延长。
final class MicService {
    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private(set) var lastURL: URL?

    var isRecording: Bool { recorder?.isRecording ?? false }

    // MARK: - 权限

    func hasPermission() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .granted { return true }
            if AVAudioApplication.shared.recordPermission == .denied { return false }
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
        }
        let status = AVAudioSession.sharedInstance().recordPermission
        if status == .granted { return true }
        if status == .denied { return false }
        return await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in cont.resume(returning: ok) }
        }
    }

    // MARK: - 录音

    /// - Parameters:
    ///   - seconds: 录音上限（1~30 秒）。VAD 只会提前停。
    ///   - silenceThreshold: 人声判定阈值（线性 RMS），默认 0.01。
    ///   - silenceMs: 说完后静音多久收尾，默认 800ms；传 0 关闭提前收尾。
    func record(seconds: Int,
                silenceThreshold: Double = 0.01,
                silenceMs: Int = 800,
                noVoiceGuardSec: Double = 2.5) async throws -> MicResult {
        guard await requestPermission() else { throw MicError.permission }
        let secs = max(1, min(30, seconds))
        let silenceLimit = max(0.0, Double(silenceMs) / 1000.0)
        let vadEnabled = silenceMs > 0

        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: [])
        } catch {
            throw MicError.session(error.localizedDescription)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString.prefix(8)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let rec: AVAudioRecorder
        do {
            rec = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw MicError.recorder(error.localizedDescription)
        }
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord(), rec.record(forDuration: TimeInterval(secs)) else {
            throw MicError.recorder("prepare/record 返回 false")
        }
        recorder = rec
        lastURL = url

        let startedAt = Date()
        var maxRMS: Double = 0
        var maxPeak: Double = 0
        var lastVoiceAt: Date?
        var speechSec: Double = 0
        var stoppedBy = "duration"

        while rec.isRecording {
            rec.updateMeters()
            let now = Date()
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed >= Double(secs) { break }

            let db = Double(rec.averagePower(forChannel: 0))
            let peakDB = Double(rec.peakPower(forChannel: 0))
            let lin = pow(10.0, db / 20.0)
            let peakLin = pow(10.0, peakDB / 20.0)
            if lin.isFinite { maxRMS = max(maxRMS, lin) }
            if peakLin.isFinite { maxPeak = max(maxPeak, peakLin) }
            let heardVoice = lin.isFinite && lin >= silenceThreshold
            if heardVoice {
                lastVoiceAt = now
                speechSec = elapsed
            }

            if vadEnabled {
                if let last = lastVoiceAt {
                    // 说过话 → 静音够久就收尾（留一点尾巴，别把最后一个字切掉）
                    if now.timeIntervalSince(last) >= silenceLimit {
                        stoppedBy = "vad"
                        break
                    }
                } else if elapsed >= noVoiceGuardSec {
                    // 一直没人说话 → 别录满上限，直接收（转写端会判定为空）
                    stoppedBy = "vad"
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let endedAt = Date()
        if rec.isRecording { rec.stop() }
        recorder = nil
        let durationSec = endedAt.timeIntervalSince(startedAt)
        let trailingSilenceMs: Int = {
            guard let last = lastVoiceAt else { return Int(durationSec * 1000) }
            return max(0, Int(endedAt.timeIntervalSince(last) * 1000))
        }()

        // 让出音频会话，KeepAlive 会把 playback 收回来。
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 44 else { throw MicError.empty }

        return MicResult(url: url,
                         durationSec: durationSec.rounded(toPlaces: 2),
                         rms: maxRMS,
                         peak: maxPeak,
                         silent: maxRMS < silenceThreshold,
                         stoppedBy: stoppedBy,
                         speechSec: speechSec.rounded(toPlaces: 2),
                         silenceMs: trailingSilenceMs,
                         maxSec: Double(secs))
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
