import AVFoundation
import Foundation
import UIKit

/// 实时感官通道（P1）：把手机麦克风变成"她的耳朵"。
///
/// 传输：`ws://<bridge>:3102/api/sense/audio?token=<设备令牌>`
/// 上行：二进制帧 = 16 kHz / 单声道 / PCM16LE（40 ms 一帧）
/// 下行：文本帧 = 控制事件（hello / say / state / heartbeat_ack），P1 不用二进制下行
///
/// 为什么是 PCM 不是 Opus：iOS 系统框架没有 Opus 编码器，而项目不允许引第三方库。
/// 256 kbps 的语音流在局域网/Tailscale 上都够用，代价是流量，收益是零依赖。
///
/// 三件系统限制导致的设计（不是偷懒）：
/// 1. 后台要活着就必须**同时**有音频输出：本类只管收音，静音播放仍由 KeepAlive 负责，
///    所以录音前必须让 KeepAlive 的交错播放让位（走 `onCaptureSessionChange`）。
/// 2. 半双工防回声：喇叭在播 TTS 时暂停上行；检测到主人开口（VAD）就打断播放（barge-in）。
/// 3. 后台上不了摄像头：这一层根本不存在"后台看"的代码路径，眼睛只在 App 前台/被唤起时工作。
final class SenseStream: NSObject {

    struct Config {
        var sampleRate: Double = 16000
        var frameMs: Int = 40
        var speechRms: Float = 0.02
        var hangoverFrames: Int = 12
        /// 一句话说完后静音多久算「这一句结束了」（毫秒）。桥接据此切段转写，
        /// 不等长句子拖满 6 秒 —— 和 MicService 的 VAD 收尾是同一套语义。
        var vadSilenceMs: Double = 800
        var heartbeatSec: Double = 5
        var reconnectDelays: [Double] = [1, 3, 9]
    }

    struct Snapshot {
        var connected = false
        var sessionId = ""
        var framesSent = 0
        var secondsSent: Double = 0
        var silentHeartbeats = 0
        var reconnects = 0
        var bargeIns = 0
        var utteranceEnds = 0
        var lastUtteranceMs: Int = 0
        var lastError = ""
        var powerMode = SensePowerMode.balanced
    }

    enum SensePowerMode: String {
        case full
        case balanced
        case low
    }

    /// 桥接推来的状态流（thinking / tool / replying）。
    var onState: ((String, String) -> Void)?
    /// 收到桥接下发的文本（P1：她说的话）。
    var onSay: ((String, String) -> Void)?
    /// 上层用来判断"现在喇叭是不是在放音"（半双工闸门）。
    var isOutputActive: (() -> Bool)?
    /// 开始/停止收音时通知 KeepAlive 让出音频会话。
    var onCaptureSessionChange: ((Bool) -> Void)?
    /// 状态变化（给首页显示）。
    var onSnapshot: ((Snapshot) -> Void)?

    private(set) var snapshot = Snapshot()
    /// 桥接为这次连接分配的会话 id；端上文字事件带上它，桥接侧好把同一段话对上。
    var sessionId: String { snapshot.sessionId }
    private var cfg = Config()
    private let engine = AVAudioEngine()
    private let sendQueue = DispatchQueue(label: "xiaobeiming.sense.send")

    private var session: URLSession
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var pending = Data()
    private var frameBytes = 1280
    private var framesSinceSpeech = 0
    private var utteranceOpen = false
    private var utteranceStartedAt = Date()
    private var utteranceFrames = 0
    private var lastHeartbeat = Date()
    private var lastSendAt = Date()
    private var reconnectAttempt = 0
    private var reconnectTask: DispatchWorkItem?
    private var receiveTask: Task<Void, Never>?
    private var sourceRate: Double = 48000
    private var lastSourceSample: Float = 0

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        super.init()
    }

    var isRunning: Bool { running }

    // MARK: - 生命周期

    func start(baseURL: URL, token: String) {
        guard !running else { return }
        guard !token.isEmpty else {
            report(error: "设备令牌为空，实时通道没启动")
            return
        }
        running = true
        reconnectAttempt = 0
        applyPowerPolicy()
        openSocket(baseURL: baseURL, token: token)
        startCapture()
    }

    func stop() {
        guard running else { return }
        running = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        stopCapture()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        snapshot.connected = false
        report(error: "")
        emit()
    }

    /// 断线后只换 socket，不重建音频引擎（麦克风 tap 还在，重配一次要 200ms 以上）。
    func reconnect(baseURL: URL, token: String) {
        guard running, !token.isEmpty else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        openSocket(baseURL: baseURL, token: token)
    }

    // MARK: - WebSocket

    private func socketURL(baseURL: URL, token: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let isSecure = (components?.scheme ?? "http").lowercased() == "https"
        components?.scheme = isSecure ? "wss" : "ws"
        // http 端点固定换到 sense.port：设备指令在 3101，实时通道在 3102。
        // https 交给隧道/反向代理，端口保持原样。
        if !isSecure {
            components?.port = DeviceHubDefaults.sensePort
        }
        components?.path = "/api/sense/audio"
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    private func openSocket(baseURL: URL, token: String) {
        guard let url = socketURL(baseURL: baseURL, token: token) else {
            report(error: "接入地址不合法，拼不出 WebSocket URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(token, forHTTPHeaderField: "x-device-token")
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        snapshot.connected = true
        snapshot.lastError = ""
        lastSendAt = Date()
        emit()
        startReceive(socket)
    }

    private func startReceive(_ socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self = self else { return }
            while self.running {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let text):
                        // 控制帧也丢到同一条串行队列，避免和 sendQueue 上的状态互相踩。
                        self.sendQueue.async { self.handle(text: text) }
                    case .data:
                        // P1 没有二进制下行；收到就忽略，别把它当错误。
                        break
                    @unknown default:
                        break
                    }
                } catch {
                    if self.running {
                        self.report(error: "实时通道断开：\(error.localizedDescription)")
                        self.scheduleReconnect()
                    }
                    return
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        switch type {
        case "hello":
            snapshot.sessionId = json["sessionId"] as? String ?? ""
            sendControl(["type": "hello", "deviceName": UIDevice.current.name, "powerMode": snapshot.powerMode.rawValue])
            emit()
        case "say":
            let spoken = json["text"] as? String ?? ""
            let audioUrl = json["audioUrl"] as? String ?? ""
            if !spoken.isEmpty || !audioUrl.isEmpty {
                onSay?(spoken, audioUrl)
            }
        case "state":
            // 桥接推来的状态流（thinking/tool/replying）：不播报，只让界面知道。
            let state = json["state"] as? String ?? ""
            let detail = json["detail"] as? String ?? ""
            if !state.isEmpty { onState?(state, detail) }
        case "utterance":
            // 服务端已经落盘，客户端不需要做任何事。
            break
        case "error":
            report(error: json["error"] as? String ?? "实时通道错误")
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard running else { return }
        reconnectTask?.cancel()
        let delays = cfg.reconnectDelays
        let index = min(reconnectAttempt, delays.count - 1)
        let delay = delays[index]
        reconnectAttempt += 1
        snapshot.reconnects += 1
        snapshot.connected = false
        emit()
        guard reconnectAttempt <= delays.count else {
            // 三次退避都失败：等 30 秒再来一轮，别把电耗在死循环上。
            reconnectAttempt = 0
            report(error: "实时通道三次重连都失败，30 秒后再试")
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.running else { return }
                self.onReconnectRequest?()
            }
            reconnectTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running else { return }
            self.onReconnectRequest?()
        }
        reconnectTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 上层（DeviceController）收到后重新调用 `start(baseURL:token:)` 即可。
    var onReconnectRequest: (() -> Void)?

    // MARK: - 采集

    private func startCapture() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            report(error: "麦克风不可用（拿不到输入格式）")
            return
        }
        sourceRate = format.sampleRate
        configureAudioSession()
        onCaptureSessionChange?(true)
        let target = cfg.sampleRate
        frameBytes = max(320, Int(target * Double(cfg.frameMs) / 1000.0) * 2)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self = self, self.running else { return }
            self.consume(buffer: buffer, sourceRate: self.sourceRate)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            report(error: "音频引擎启动失败：\(error.localizedDescription)")
        }
    }

    private func stopCapture() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        pending = Data()
        onCaptureSessionChange?(false)
    }

    private func configureAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        do {
            // 必须 playAndRecord：纯录音在后台会被系统挂起；输出轨由 KeepAlive 的静音循环维持。
            try audio.setCategory(.playAndRecord,
                                  mode: .default,
                                  options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audio.setPreferredSampleRate(16000)
            try audio.setPreferredIOBufferDuration(0.02)
            try audio.setActive(true, options: [])
        } catch {
            report(error: "音频会话配置失败：\(error.localizedDescription)")
        }
    }

    /// 音频线程里只做「降采样 → RMS → 累积 → 丢给发送队列」，不做 I/O。
    private func consume(buffer: AVAudioPCMBuffer, sourceRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let target = cfg.sampleRate
        let ratio = sourceRate / max(target, 1)
        let outCount = max(1, Int(Double(count) / ratio))
        var pcm = [Int16](repeating: 0, count: outCount)
        var sum: Double = 0
        var previous = lastSourceSample
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let base = Int(pos)
            let frac = Float(pos - Double(base))
            let a = base < count ? channel[base] : previous
            let b = base + 1 < count ? channel[base + 1] : a
            let value = a + (b - a) * frac
            previous = value
            sum += Double(value) * Double(value)
            let clamped = max(-1.0, min(1.0, Double(value)))
            pcm[i] = Int16(clamped * 32767.0)
        }
        lastSourceSample = previous
        let rms = Float(sqrt(sum / Double(outCount)))

        var data = Data(capacity: outCount * 2)
        pcm.withUnsafeBufferPointer { raw in
            data.append(UnsafeBufferPointer(start: raw.baseAddress, count: raw.count))
        }
        sendQueue.async { [weak self] in
            self?.enqueue(data: data, rms: rms)
        }
    }

    // MARK: - VAD + 发送

    private func enqueue(data: Data, rms: Float) {
        pending.append(data)
        let speaking = rms >= cfg.speechRms
        if speaking {
            framesSinceSpeech = 0
        } else {
            framesSinceSpeech += 1
        }
        // ── 一句话的边界：说完了、静音够久 → 告诉桥接「这一句结束」，可以去切段转写了。
        // 以前这里只在静音期发心跳，桥接只能靠自己的静音计数猜句子边界，
        // 于是「她听到你说完」要等更久。现在由手机直接给边界（带上这句话多长）。
        if speaking {
            if !utteranceOpen {
                utteranceOpen = true
                utteranceStartedAt = Date()
                utteranceFrames = 0
                sendControl(["type": "speech_start"])
            }
            utteranceFrames += 1
        } else if utteranceOpen {
            let silenceMs = Double(framesSinceSpeech * cfg.frameMs)
            if silenceMs >= cfg.vadSilenceMs {
                utteranceOpen = false
                let totalMs = Int(Date().timeIntervalSince(utteranceStartedAt) * 1000)
                snapshot.utteranceEnds += 1
                snapshot.lastUtteranceMs = totalMs
                sendControl([
                    "type": "speech_end",
                    "utteranceMs": totalMs,
                    "silenceMs": Int(silenceMs),
                    "frames": utteranceFrames,
                ])
                emit()
            }
        }
        let outputActive = isOutputActive?() ?? false
        if speaking && outputActive {
            // 打断：喇叭还开着但主人在说话 → 交给上层停 TTS，这一小段不上行（防回声）。
            bargeIn()
            pending.removeAll()
            return
        }
        while pending.count >= frameBytes {
            let chunk = pending.prefix(frameBytes)
            pending.removeFirst(frameBytes)
            if outputActive {
                // 半双工：她在说话时不把麦克风推上去，避免把自己的声音当成主人的输入。
                continue
            }
            send(binary: Data(chunk))
            snapshot.framesSent += 1
            snapshot.secondsSent += Double(frameBytes / 2) / cfg.sampleRate
        }
        maybeHeartbeat(speaking: speaking)
    }

    private func bargeIn() {
        snapshot.bargeIns += 1
        emit()
        DispatchQueue.main.async { [weak self] in
            self?.onBargeIn?()
        }
    }

    var onBargeIn: (() -> Void)?

    private func maybeHeartbeat(speaking: Bool) {
        let now = Date()
        let idleFor = now.timeIntervalSince(lastSendAt)
        if speaking {
            lastSendAt = now
            return
        }
        if now.timeIntervalSince(lastHeartbeat) >= cfg.heartbeatSec || idleFor >= cfg.heartbeatSec {
            lastHeartbeat = now
            snapshot.silentHeartbeats += 1
            sendControl(["type": "heartbeat", "powerMode": snapshot.powerMode.rawValue])
            emit()
        }
    }

    private func send(binary data: Data) {
        guard let task = task else { return }
        lastSendAt = Date()
        task.send(.data(data)) { [weak self] error in
            if let error = error {
                self?.report(error: "上行发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func sendControl(_ object: [String: Any]) {
        guard let task = task else { return }
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        guard let text = String(data: payload, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.report(error: "控制帧发送失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 功耗策略

    /// 省电模式或电量低：降采样到 8 kHz、VAD 更迟钝、心跳更稀疏。
    private func applyPowerPolicy() {
        let info = ProcessInfo.processInfo
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        var mode: SensePowerMode = .balanced
        if charging && UIApplication.shared.applicationState == .active {
            mode = .full
        } else if info.isLowPowerModeEnabled || (level >= 0 && level < 0.2) {
            mode = .low
        }
        snapshot.powerMode = mode
        switch mode {
        case .full:
            cfg.sampleRate = 16000
            cfg.speechRms = 0.018
            cfg.heartbeatSec = 5
        case .balanced:
            cfg.sampleRate = 16000
            cfg.speechRms = 0.02
            cfg.heartbeatSec = 5
        case .low:
            cfg.sampleRate = 8000
            cfg.speechRms = 0.035
            cfg.heartbeatSec = 10
        }
        emit()
    }

    /// 前后台切换 / 电量变化时调用。
    func refreshPowerPolicy() {
        guard running else { return }
        applyPowerPolicy()
    }

    // MARK: - 状态

    private func report(error message: String) {
        snapshot.lastError = message
        emit()
    }

    private func emit() {
        let current = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(current)
        }
    }
}
