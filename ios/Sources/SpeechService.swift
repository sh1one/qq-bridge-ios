import AVFoundation
import Foundation

enum SpeechError: LocalizedError {
    case badURL
    case download(String)
    case tooLarge(Int)
    case player(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "音频地址不合法（只接受 http/https）"
        case .download(let why): return "音频下载失败：\(why)"
        case .tooLarge(let n): return "音频太大：\(n) 字节（上限 8MB）"
        case .player(let why): return "播放器启动失败：\(why)"
        }
    }
}

/// 嘴。两条路：
/// 1) 桥接下发的音频 URL（她自己的克隆音色）→ 下载到临时文件后用 AVAudioPlayer 播；
/// 2) 只有文字时 → AVSpeechSynthesizer 用 zh-CN 系统音色兜底（机械音，仅兜底）。
final class SpeechService {
    private let session = AVAudioSession.sharedInstance()
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var tempFile: URL?
    private let maxBytes = 8 * 1024 * 1024

    private func activate() throws {
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true, options: [])
    }

    // MARK: - 播放克隆音色

    /// 下载并开始播放。返回后音频继续播（不等播完，避免一条长音频把指令拖到超时）。
    func playRemote(urlString: String, volume: Float = 1.0) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SpeechError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let data: Data
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw SpeechError.download("HTTP \(http.statusCode)")
            }
            data = d
        } catch let e as SpeechError {
            throw e
        } catch {
            throw SpeechError.download(error.localizedDescription)
        }
        guard data.count <= maxBytes else { throw SpeechError.tooLarge(data.count) }
        guard !data.isEmpty else { throw SpeechError.download("内容为空") }

        let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("say-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            throw SpeechError.download("写临时文件失败：\(error.localizedDescription)")
        }

        stopPlayer()

        do {
            try activate()
            let p = try AVAudioPlayer(contentsOf: file)
            p.volume = max(0, min(1, volume))
            p.prepareToPlay()
            guard p.play() else { throw SpeechError.player("play() 返回 false") }
            player = p
            tempFile = file
        } catch let e as SpeechError {
            throw e
        } catch {
            throw SpeechError.player(error.localizedDescription)
        }
        return ext.lowercased()
    }

    // MARK: - 系统 TTS 兜底

    @discardableResult
    func speak(text: String, volume: Float = 1.0, rate: Float = 0.48) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        try activate()
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = max(0.3, min(0.6, rate))
        utterance.volume = max(0, min(1, volume))
        synth.speak(utterance)
        return trimmed.count
    }

    // MARK: - 停止

    func stopPlayer() {
        player?.stop()
        player = nil
        if let file = tempFile {
            try? FileManager.default.removeItem(at: file)
            tempFile = nil
        }
    }

    func stopAll() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        stopPlayer()
    }

    var isSpeaking: Bool { (player?.isPlaying ?? false) || synth.isSpeaking }
}
