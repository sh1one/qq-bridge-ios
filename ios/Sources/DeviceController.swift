import Combine
import Foundation
import UIKit

/// 把桥接指令翻译成手机上的动作。
///
/// 分寸都写在这里，不是口号：
/// - 没有任何定时器会自己拍照/录音，只有 handle() 收到 look/listen 才动硬件；
/// - 每次 look/listen 之前先把提示写到屏幕上并停留 0.7 秒，再采集；
/// - 每次执行（成功或失败）都往本地 audit 日志追加一条，App 自己就能查。
///
/// 接入方式是多通道择优：家里 WiFi（lan）、Tailscale（tailscale）、隧道域名（tunnel）。
/// 出门在外时 lan 会在 3 秒探测里失败，自动落到 tailscale 或 tunnel。
@MainActor
final class DeviceController: ObservableObject {
    @Published var connState: String = "未启动"
    @Published var connected: Bool = false
    @Published var batteryText: String = "—"
    @Published var notice: String?
    @Published var lastError: String = ""
    @Published var awake: Bool = false

    /// 三条通道的地址（只填需要的；顺序固定 lan → tailscale → tunnel）。
    @Published var lanURL: String = ""
    @Published var tailscaleURL: String = ""
    @Published var tunnelURL: String = ""

    /// 手填的引导令牌（等于桥接 state/device/token 或 config.device.token）。
    @Published var token: String = ""
    @Published var tokenConfigured: Bool = false

    /// 当前实际走哪条通道，以及每条通道的探测结果（首页用来排查）。
    @Published var activeChannel: String = "未连接"
    @Published var channelDetail: String = ""
    /// 她此刻在做什么（桥接状态流：thinking / tool / replying）。
    @Published var activity: String = "空闲"

    /// 端上识别与 VAD 的用户设置（单独存，和桥接地址互不影响）。
    @Published var settings = AppSettings.load()
    /// WhisperKit 下载/加载/转写状态，设置页直接显示。
    @Published var asrState = ASRState()
    /// 常驻监听（CallKit）的状态：设置页和 listenStart 命令都读这几项。
    @Published var listenRunning = false
    @Published var listenSegments = 0
    @Published var listenLastText = ""
    @Published var listenLastError = ""

    private let bridge = BridgeClient()
    private let keepAlive = KeepAlive()
    private let camera = CameraService()
    private let mic = MicService()
    private let speech = SpeechService()
    private let haptics = HapticsService()
    private let opener = OpenAppService()
    private let sense = SenseStream()
    private let asr = OnDeviceASR()
    /// 常驻监听（CallKit）。它自带一份 BridgeClient 打 `/api/device/speech`，
    /// 这样选路/配对随时改 baseURL 也不会把正在飞的那一段打断。
    /// 用 lazy 是因为它要拿 `asr` 这个实例（同一个 WhisperKit，不重复 load 模型）。
    private lazy var listen = ListenMode(asr: asr)
    private var router = EndpointRouter()

    private var heartbeatTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var bootstrapped = false

    /// 配对得到的设备身份；为空时用引导令牌工作。
    private var deviceId: String = ""
    private var deviceToken: String = ""

    private enum Keys {
        static let lanURL = "bridge.lan.url"
        static let tailscaleURL = "bridge.tailscale.url"
        static let tunnelURL = "bridge.tunnel.url"
        static let token = "bridge.token"
        static let deviceId = "bridge.device.id"
        static let deviceToken = "bridge.device.token"
        static let awake = "app.awake"
    }

    // MARK: - 生命周期

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let defaults = UserDefaults.standard
        settings = AppSettings.load()
        asr.onUpdate = { [weak self] state in
            self?.asrState = state
        }
        // ListenMode 的回调在主线程但不在 MainActor 上，照 sense.onState 的先例跳一次再写 @Published。
        listen.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                guard let self = self else { return }
                self.listenRunning = snapshot.isRunning
                self.listenSegments = snapshot.segments
                self.listenLastText = snapshot.lastText
                self.listenLastError = snapshot.lastError
            }
        }
        lanURL = defaults.string(forKey: Keys.lanURL) ?? ""
        tailscaleURL = defaults.string(forKey: Keys.tailscaleURL) ?? ""
        tunnelURL = defaults.string(forKey: Keys.tunnelURL) ?? ""
        token = defaults.string(forKey: Keys.token) ?? ""
        deviceId = defaults.string(forKey: Keys.deviceId) ?? ""
        deviceToken = defaults.string(forKey: Keys.deviceToken) ?? ""
        if deviceId.isEmpty {
            deviceId = Self.makeDeviceId()
            defaults.set(deviceId, forKey: Keys.deviceId)
        }
        tokenConfigured = !token.isEmpty && !endpoints.isEmpty
        applyBridgeConfig()
        router.updateEndpoints(endpoints)
        updateChannelDisplay()

        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.updateBattery()
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.updateBattery()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // 进后台时确保保活音频在放，否则会被立刻挂起。
            guard let self = self, self.awake else { return }
            self.keepAlive.start()
        }

        if tokenConfigured {
            let wantAwake = defaults.object(forKey: Keys.awake) as? Bool ?? true
            if wantAwake { startAwake() }
        } else {
            connState = "未配置通道或 token"
        }
    }

    func saveSettings(lan: String, tailscale: String, tunnel: String, token newToken: String) {
        let defaults = UserDefaults.standard
        lanURL = lan.trimmingCharacters(in: .whitespacesAndNewlines)
        tailscaleURL = tailscale.trimmingCharacters(in: .whitespacesAndNewlines)
        tunnelURL = tunnel.trimmingCharacters(in: .whitespacesAndNewlines)
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(lanURL, forKey: Keys.lanURL)
        defaults.set(tailscaleURL, forKey: Keys.tailscaleURL)
        defaults.set(tunnelURL, forKey: Keys.tunnelURL)
        defaults.set(token, forKey: Keys.token)
        tokenConfigured = !token.isEmpty && !endpoints.isEmpty
        applyBridgeConfig()
        router.updateEndpoints(endpoints)
        updateChannelDisplay()
        if tokenConfigured {
            if awake { stopAwake(reason: "重新连接中…") }
            startAwake()
        } else {
            stopAwake(reason: "没有可用通道或 token 为空，按约定不发起连接")
        }
    }

    /// 保存端上识别 + 常驻监听相关设置。不动桥接连接，下一次 listen 生效。
    func updateAppSettings(useOnDeviceASR: Bool,
                           model: OnDeviceModel,
                           vadSilenceMs: Int,
                           vadThreshold: Double,
                           continuousListen: Bool) {
        // 先记下开关的变化方向：下面写 settings 之后就分不出「本来就开着」和「刚打开」了。
        let listenTurnedOn = continuousListen && !settings.continuousListen
        let listenTurnedOff = !continuousListen && settings.continuousListen
        settings.useOnDeviceASR = useOnDeviceASR
        settings.onDeviceModel = model.rawValue
        settings.vadSilenceMs = max(200, min(3000, vadSilenceMs))
        settings.vadThreshold = max(0.005, min(0.2, vadThreshold))
        settings.continuousListen = continuousListen
        settings.save()
        syncListenEndpoint()
        // 第一次打开就按需下载并预编译；进度在设置页和 asrState 里。
        if settings.useOnDeviceASR {
            Task { await prepareASR() }
        }
        // 这个开关的语义是「现在就开始听 / 现在别听了」，所以立刻生效，不等下一次指令。
        if listenTurnedOn {
            guard awake, router.activeURL != nil else {
                // 还没连上就先只提示：startLoops() 连上以后会按这个开关自动拉起。
                listenLastError = "已保存；连上电脑后自动开始常驻监听"
                return
            }
            Task { [weak self] in
                guard let self = self else { return }
                let outcome = await self.startContinuousListen()
                if !outcome.ok { self.lastError = outcome.error }
            }
        } else if listenTurnedOff {
            stopContinuousListen()
            listenLastError = ""
        }
    }

    /// 设置页「准备模型」：下载 + CoreML 预编译。首次 small 可能要几十秒到几分钟。
    func prepareASR() async {
        await asr.prepare(preferredModel: settings.onDeviceModel)
    }

    func toggleAwake() {
        if awake {
            stopAwake(reason: "手动待机")
        } else {
            guard tokenConfigured else {
                lastError = "先点右上角填接入通道和令牌"
                connState = "未配置"
                return
            }
            startAwake()
        }
    }

    private var endpoints: [BridgeEndpoint] {
        var list: [BridgeEndpoint] = []
        let lan = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tailscale = tailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnel = tunnelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lan.isEmpty { list.append(BridgeEndpoint(tag: "lan", url: lan)) }
        if !tailscale.isEmpty { list.append(BridgeEndpoint(tag: "tailscale", url: tailscale)) }
        if !tunnel.isEmpty { list.append(BridgeEndpoint(tag: "tunnel", url: tunnel)) }
        return list
    }

    private func applyBridgeConfig() {
        bridge.bootstrapToken = token
        bridge.deviceToken = deviceToken
    }

    private func startAwake() {
        guard tokenConfigured, !awake else { return }
        awake = true
        UserDefaults.standard.set(true, forKey: Keys.awake)
        keepAlive.start()
        if !keepAlive.lastError.isEmpty { lastError = keepAlive.lastError }
        connState = "探测接入通道…"
        connectTask?.cancel()
        heartbeatTask?.cancel()
        pollTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self = self else { return }
            let ready = await self.connect()
            guard ready, self.awake else { return }
            self.startLoops()
        }
    }

    private func startLoops() {
        heartbeatTask?.cancel()
        pollTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self = self else { return }
            await self.heartbeatLoop()
        }
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            await self.pollLoop()
        }
        // 麦克风只有一只：常驻监听（CallKit）和实时感官通道（3102）共用不了。
        // 两个 AVAudioEngine 同时读 inputNode 会互相打断（一个把会话切成 voiceChat，
        // 另一个按 playAndRecord 抢回来），结果是两边都听不清。所以开关开着就把麦克风
        // 交给常驻监听，关着才走实时音频流。
        if settings.continuousListen {
            Task { [weak self] in
                guard let self = self else { return }
                let outcome = await self.startContinuousListen()
                if !outcome.ok { self.lastError = outcome.error }
            }
        } else {
            startSense()
        }
    }

    // MARK: - 实时感官通道（P1）

    /// 常驻收音：配对成功后把麦克风挂到桥接的 3102 端口。
    /// 只在 awake 且已拿到设备令牌时启动 —— 用引导令牌连上去只会被 401 赶回来。
    private func startSense() {
        guard let baseURL = router.activeURL else {
            lastError = "没有可用接入通道，实时音频未启动"
            return
        }
        let credential = deviceToken.isEmpty ? token : deviceToken
        guard !credential.isEmpty else {
            lastError = "还没拿到设备令牌，实时音频未启动"
            return
        }
        sense.isOutputActive = { [weak self] in
            guard let self = self else { return false }
            return self.speech.isSpeaking
        }
        sense.onCaptureSessionChange = { [weak self] active in
            guard let self = self else { return }
            if active {
                self.keepAlive.suspendForRecording()
            } else {
                self.keepAlive.resumeAfterRecording()
            }
        }
        sense.onState = { [weak self] state, detail in
            // 桥接推来的状态流：thinking / tool / replying，直接映到首页那一行。
            Task { @MainActor in
                guard let self = self else { return }
                let map: [String: String] = ["thinking": "在想…", "tool": "在动手…", "replying": "在回话"]
                let label = map[state] ?? state
                self.activity = detail.isEmpty ? label : "\(label)（\(detail)）"
            }
        }
        sense.onSay = { [weak self] text, audioUrl in
            guard let self = self else { return }
            Task { @MainActor in
                if !audioUrl.isEmpty {
                    _ = try? await self.speech.playRemote(urlString: audioUrl, volume: 1.0)
                } else if !text.isEmpty {
                    _ = try? self.speech.speak(text: text, volume: 1.0, rate: 0.5)
                }
            }
        }
        sense.onBargeIn = { [weak self] in
            // 主人开口了：先闭嘴，再把这一句记进本地日志。
            guard let self = self else { return }
            self.speech.stopAll()
            self.audit(cmd: "barge_in", id: "", ok: true, error: "", data: ["channel": self.activeChannel])
        }
        sense.onReconnectRequest = { [weak self] in
            guard let self = self, let url = self.router.activeURL else { return }
            self.sense.reconnect(baseURL: url, token: self.deviceToken.isEmpty ? self.token : self.deviceToken)
        }
        sense.start(baseURL: baseURL, token: credential)
    }

    // MARK: - 常驻监听（CallKit）

    /// 把最新的通道/令牌/模型同步给常驻监听：它自己发 HTTP，用的是另一份 BridgeClient。
    /// 选路切换、重新配对、改模型之后都要调，否则新段落会往旧地址发。
    private func syncListenEndpoint() {
        guard let base = router.activeURL ?? bridge.baseURL else { return }
        let credential = deviceToken.isEmpty ? token : deviceToken
        guard !credential.isEmpty else { return }
        listen.configure(baseURL: base, token: credential, model: settings.onDeviceModel)
    }

    /// 起常驻监听；返回 (是否成功, 失败原因)。运行状态另外经 listen.onSnapshot 刷到 @Published。
    ///
    /// 这里集中处理三件互斥的事，顺序不能换：
    /// 1) 单次录音在跑 → 直接拒绝（两路抢同一个麦克风，谁的声音都不完整）；
    /// 2) `SenseStream` 的实时音频 → 先停（它有自己独立的 AVAudioEngine）；
    /// 3) `KeepAlive` 的静音播放 → 先让出（常驻监听要自己占音频会话）。
    private func startContinuousListen() async -> (ok: Bool, error: String) {
        if listen.isRunning { return (true, "") }
        if mic.isRecording {
            return (false, "正在做单次录音，等它结束后再开常驻监听")
        }
        // 权限要在起 engine 之前问，否则 tap 装上了也拿不到数据。
        guard await mic.requestPermission() else {
            return (false, "没有麦克风权限：去「设置 → 小北冥 → 麦克风」打开")
        }
        guard let base = router.activeURL ?? bridge.baseURL else {
            return (false, "还没有可用接入通道，转写出来的文字发不出去")
        }
        let credential = deviceToken.isEmpty ? token : deviceToken
        guard !credential.isEmpty else {
            return (false, "还没有设备令牌，先让 App 连上电脑")
        }

        sense.stop()
        keepAlive.suspendForRecording()
        listen.configure(baseURL: base, token: credential, model: settings.onDeviceModel)
        var config = ListenMode.Config()
        config.threshold = settings.vadThreshold
        // 常驻监听沿用设置页那个「静音多久算说完」，不另立一套，用户调一次两边一致。
        config.silenceMs = max(600, settings.vadSilenceMs)
        guard listen.start(config: config) else {
            // 起不来就把音频会话还回去，别让麦克风一直占着。
            keepAlive.resumeAfterRecording()
            if awake, router.activeURL != nil { startSense() }
            let reason = listen.snapshot.lastError
            return (false, reason.isEmpty ? "常驻监听启动失败" : reason)
        }

        // 模型没准备好就后台准备：不阻塞这条指令的返回；准备期间的段落会失败并记进 listenLastError。
        if !asr.isReady(preferredModel: settings.onDeviceModel) {
            Task { await prepareASR() }
        }
        lastError = ""
        return (true, "")
    }

    /// 停常驻监听，并把麦克风还给实时感官通道。幂等：没在跑时什么也不做。
    private func stopContinuousListen() {
        guard listen.isRunning else { return }
        // 顺序要紧：先停监听（它会 setActive(false)），再恢复保活播放，否则保活会被一起踢掉。
        // 走 stopByUser：用户手动关掉就顺手清掉「一直听」的意图，否则下次连上会被自动拉起。
        listen.stopByUser()
        keepAlive.resumeAfterRecording()
        if awake, router.activeURL != nil { startSense() }
    }

    private func stopAwake(reason: String) {
        awake = false
        UserDefaults.standard.set(false, forKey: Keys.awake)
        connectTask?.cancel()
        heartbeatTask?.cancel()
        pollTask?.cancel()
        connectTask = nil
        heartbeatTask = nil
        pollTask = nil
        keepAlive.stop()
        sense.stop()
        // 待机/重连都要把麦克风彻底放掉：挂着 CallKit 通话不放，用户会以为 App 还在偷听。
        listen.stop()
        camera.shutdown()
        speech.stopAll()
        haptics.stop()
        connected = false
        activeChannel = "未连接"
        connState = reason
    }

    private static func makeDeviceId() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(24))
    }

    // MARK: - 连接与择优

    /// 择优 → 配对。返回是否已经有一条可用通道。
    private func connect() async -> Bool {
        let list = endpoints
        guard !list.isEmpty else {
            lastError = "没有配置任何接入通道"
            connState = "未配置"
            return false
        }

        var probe = await router.refreshActive(token: bridge.token)
        if probe == nil, bridge.isPaired {
            // 设备令牌被吊销/重置会让所有端点都回 401/403，看起来像"全不通"。
            // 退回引导令牌再探一轮，通了就重新配对。
            probe = await router.refreshActive(token: token)
        }
        guard let hit = probe, let base = router.activeURL else {
            connState = "所有通道都连不上"
            lastError = "lan/tailscale/tunnel 全部不可达；30 秒后会自动重新探测"
            updateChannelDisplay()
            return false
        }

        bridge.baseURL = base
        activeChannel = hit.tag
        updateChannelDisplay()
        connState = "已连接 · \(hit.tag) · \(hit.latencyMs)ms"
        if !bridge.isPaired {
            await pairIfNeeded()
        }
        connected = true
        syncListenEndpoint()
        return true
    }

    /// 配对只为拿到一次性设备令牌（可单独吊销）；失败不阻断，引导令牌仍可用。
    private func pairIfNeeded() async {
        guard bridge.baseURL != nil else { return }
        do {
            let reply = try await bridge.pair(deviceId: deviceId, deviceName: UIDevice.current.name)
            deviceId = reply.deviceId
            deviceToken = reply.deviceToken
            bridge.deviceToken = reply.deviceToken
            let defaults = UserDefaults.standard
            defaults.set(reply.deviceId, forKey: Keys.deviceId)
            defaults.set(reply.deviceToken, forKey: Keys.deviceToken)
        } catch {
            lastError = "设备配对失败（仍可继续，但无法单独吊销）：\(BridgeClient.describe(error))"
        }
    }

    /// 拿一个可用 baseURL；全都不通且还在冷却期时返回 nil，让调用方睡一会。
    private func ensureEndpoint() async -> URL? {
        if let live = router.activeURL {
            bridge.baseURL = live
            return live
        }
        if router.inCooldown { return nil }
        _ = await router.refreshActive(token: bridge.token)
        if let base = router.activeURL {
            bridge.baseURL = base
            updateChannelDisplay()
            return base
        }
        return nil
    }

    /// 失败处理：鉴权失败优先重新配对，其余按"连续 3 次才换通道"。
    /// 返回 true 表示已经换了通道（调用方可以立刻重试一次）。
    private func handleFailure(_ error: Error) async -> Bool {
        if let status = (error as? BridgeError)?.httpStatus, status == 401 || status == 403, bridge.isPaired {
            bridge.deviceToken = ""
            deviceToken = ""
            UserDefaults.standard.removeObject(forKey: Keys.deviceToken)
            if await router.refreshActive(token: token) != nil {
                bridge.baseURL = router.activeURL
                await pairIfNeeded()
                updateChannelDisplay()
                syncListenEndpoint()
                return true
            }
            updateChannelDisplay()
            return false
        }

        if router.noteFailure() {
            if await router.failover(token: bridge.token) != nil {
                bridge.baseURL = router.activeURL
                updateChannelDisplay()
                if !bridge.isPaired { await pairIfNeeded() }
                syncListenEndpoint()
                return true
            }
            updateChannelDisplay()
        }
        return false
    }

    private func updateChannelDisplay() {
        activeChannel = router.activeTag
        let parts = router.channelList.map { channel -> String in
            if channel.active { return "\(channel.tag):当前" }
            if let latency = channel.latencyMs { return "\(channel.tag):\(latency)ms" }
            if channel.lastFailAt != nil { return "\(channel.tag):不通" }
            return "\(channel.tag):未探测"
        }
        channelDetail = parts.isEmpty ? "还没有配置通道" : parts.joined(separator: " · ")
    }

    // MARK: - 电量

    private var currentBattery: Int? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    private var charging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        default: return false
        }
    }

    private func updateBattery() {
        if let battery = currentBattery {
            batteryText = "\(battery)%\(charging ? " ⚡︎" : "")"
        } else {
            batteryText = "未知"
        }
    }

    // MARK: - 心跳

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            guard awake else { return }
            guard await ensureEndpoint() != nil else {
                connected = false
                connState = router.inCooldown ? "所有通道不可达，30 秒后重试" : "等待通道…"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            do {
                let ls = listen.snapshot
                let reply = try await bridge.heartbeat(battery: currentBattery ?? -1,
                                                       charging: charging,
                                                       mode: awake ? "awake" : "standby",
                                                       deviceName: UIDevice.current.name,
                                                       lastError: lastError,
                                                       channels: router.channelList.map { $0.payload },
                                                       listen: ["running": ls.isRunning,
                                                                "wants": ls.wants,
                                                                "callActive": ls.callActive,
                                                                "segments": ls.segments,
                                                                "pending": ls.pending,
                                                                "lastError": ls.lastError])
                router.noteSuccess()
                connected = true
                activeChannel = router.activeTag
                connState = "已连接 · \(router.activeTag)"
                updateChannelDisplay()
                try? await Task.sleep(nanoseconds: UInt64(reply.nextInterval * 1_000_000_000))
            } catch {
                connected = false
                lastError = BridgeClient.describe(error)
                let switched = await handleFailure(error)
                connState = switched ? "已切到 · \(router.activeTag)" : "心跳失败：\(lastError)"
                try? await Task.sleep(nanoseconds: switched ? 500_000_000 : 3_000_000_000)
            }
        }
    }

    // MARK: - 长轮询

    private func pollLoop() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            guard awake else { return }
            guard await ensureEndpoint() != nil else {
                connState = router.inCooldown ? "所有通道不可达，30 秒后重试" : "等待通道…"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            do {
                let commands = try await bridge.poll(waitSeconds: 25)
                router.noteSuccess()
                connected = true
                activeChannel = router.activeTag
                connState = "已连接 · \(router.activeTag)"
                lastError = ""
                backoff = 1
                for command in commands {
                    await handle(command)
                }
            } catch {
                connected = false
                let message = BridgeClient.describe(error)
                let switched = await handleFailure(error)
                connState = switched ? "已切到 · \(router.activeTag)" : "断线（\(backoff)s 后重连）：\(message)"
                lastError = message
                if !awake { return }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    // MARK: - 指令执行

    private func handle(_ command: DeviceCommand) async {
        var data: [String: Any] = [:]
        var media: (ext: String, base64: String)?
        var ok = true
        var errorText = ""

        // 常驻监听和单次录音互斥。放在 switch 之前，好让 "listen" 分支保持原样：
        // 常驻监听占着麦克风时再接一次 listen，只会录到一段静音，还得跟 CallKit 抢音频会话。
        if command.cmd == "listen", listen.isRunning {
            data = [
                "mode": "continuous",
                "note": "常驻监听中，请改用文字流",
                "segments": listenSegments,
                "format": "text",
            ]
            audit(cmd: command.cmd, id: command.id, ok: true, error: "", data: data)
            do {
                try await bridge.report(id: command.id, ok: true, data: data, error: "", media: nil)
            } catch {
                lastError = "结果上报失败：\(Self.short(error))"
            }
            return
        }

        switch command.cmd {
        case "look":
            let camera = command.string("camera", fallback: "back")
            await showNotice("📷 正在拍照（\(camera == "front" ? "前置" : "后置")）· 由小北冥请求", hold: 3.0)
            do {
                let (jpeg, width, height) = try await self.camera.captureJPEG(camera: camera)
                data = ["width": width, "height": height, "camera": camera, "bytes": jpeg.count, "visibleNoticeMs": 3000]
                media = ("jpg", jpeg.base64EncodedString())
            } catch {
                ok = false
                errorText = Self.short(error)
            }

        case "listen":
            let seconds = command.int("seconds", fallback: 5)
            // 说完即停：桥接把 seconds 当「上限」，silenceMs 决定「静音多久算说完」。
            let silenceMs = command.int("silenceMs", fallback: settings.vadSilenceMs)
            let useVad = command.bool("vad", fallback: true)
            let wantsOnDevice = command.bool("onDeviceASR", fallback: settings.useOnDeviceASR)
            await showNotice("🎙 正在录音（最多 \(seconds) 秒，说完自动停）· 由小北冥请求", hold: 3.0)
            keepAlive.suspendForRecording()
            do {
                let result = try await mic.record(
                    seconds: seconds,
                    silenceThreshold: settings.vadThreshold,
                    silenceMs: useVad ? silenceMs : 0
                )
                data = [
                    "durationSec": result.durationSec,
                    "maxSec": result.maxSec,
                    "stoppedBy": result.stoppedBy,
                    "speechSec": result.speechSec,
                    "silenceMs": result.silenceMs,
                    "vad": useVad,
                    "format": "wav",
                    "sampleRate": 16000,
                    "channels": 1,
                    "rms": (result.rms * 10_000).rounded() / 10_000,
                    "peak": (result.peak * 10_000).rounded() / 10_000,
                    "silent": result.silent,
                    "bytes": (try? Data(contentsOf: result.url).count) ?? 0,
                ]
                if !result.silent {
                    var usedOnDevice = false
                    let onDeviceReady = wantsOnDevice && asr.isReady(preferredModel: settings.onDeviceModel)
                    if wantsOnDevice && !onDeviceReady {
                        // 不在 listen 里等模型下载：没准备好就退回音频上传，桥接照旧转写。
                        data["onDeviceASR"] = "not-ready"
                        data["onDeviceASRHint"] = "模型未准备，本次回退服务端转写"
                    }
                    if onDeviceReady {
                        do {
                            let asrResult = try await asr.transcribe(
                                wavURL: result.url,
                                durationSec: result.durationSec,
                                preferredModel: settings.onDeviceModel
                            )
                            if asrResult.text.isEmpty {
                                data["onDeviceASRError"] = "端上识别没有返回文字"
                            } else {
                                data["transcript"] = asrResult.text
                                data["sttMs"] = asrResult.ms
                                data["sttModel"] = asrResult.model
                                data["sttSource"] = "device"
                                data["onDeviceASR"] = true
                                usedOnDevice = true
                                // 文字事件走感官通道（3102）；音频不离开手机。
                                do {
                                    _ = try await bridge.postUtterance(
                                        text: asrResult.text,
                                        ms: asrResult.ms,
                                        model: asrResult.model,
                                        durationSec: result.durationSec,
                                        sessionId: sense.sessionId
                                    )
                                    data["utterancePosted"] = true
                                } catch {
                                    // 事件没送到也不影响 report；桥接侧还能从 data 里拿到文字。
                                    data["utterancePostError"] = Self.short(error)
                                }
                            }
                        } catch {
                            data["onDeviceASRError"] = Self.short(error)
                        }
                    }
                    if !usedOnDevice, let audio = try? Data(contentsOf: result.url) {
                        // 兜底：端上识别失败/关闭时仍走原来的音频上传 + 桥接转写。
                        media = ("wav", audio.base64EncodedString())
                    }
                }
            } catch {
                ok = false
                errorText = Self.short(error)
            }
            keepAlive.resumeAfterRecording()

        case "say":
            let audioUrl = command.string("audioUrl")
            let text = command.string("text")
            let volume = Float(min(max(command.double("volume", fallback: 1), 0), 1))
            if !audioUrl.isEmpty {
                do {
                    let ext = try await speech.playRemote(urlString: audioUrl, volume: volume)
                    data = ["route": "audio", "audioUrl": audioUrl, "ext": ext]
                } catch {
                    ok = false
                    errorText = Self.short(error)
                }
            } else if !text.isEmpty {
                do {
                    let chars = try speech.speak(text: text, volume: volume)
                    data = ["route": "tts", "chars": chars, "voice": "zh-CN"]
                } catch {
                    ok = false
                    errorText = Self.short(error)
                }
            } else {
                ok = false
                errorText = "say 需要 text 或 audioUrl（audioPath 由桥接换成 audioUrl 再下发）"
            }

        case "haptic":
            let pattern = command.string("pattern", fallback: "pulse")
            let result = haptics.play(pattern: pattern, intensity: command.double("intensity", fallback: 0.7))
            data = ["pattern": pattern, "fallback": result.fallback, "supported": haptics.supportsHaptics]
            if !result.ok {
                ok = false
                errorText = haptics.lastError.isEmpty ? "触觉播放失败" : haptics.lastError
            }

        case "openApp":
            let result = await opener.open(command.string("url"))
            data = ["url": result.url, "opened": result.opened, "foreground": result.foreground]
            if !result.opened {
                ok = false
                errorText = result.error
            }

        case "torch":
            let on = command.bool("on", fallback: true)
            let supported = camera.setTorch(on)
            data = ["on": on, "supported": supported]
            if !supported {
                ok = false
                errorText = "这台设备没有可用手电筒（或相机未授权）"
            }

        case "ping":
            data = ["pong": true, "appVersion": BridgeClient.appVersion(), "mode": awake ? "awake" : "standby"]

        case "listenStart":
            // payload 为空即可：阈值/静音时长走设置，桥接不需要关心这些参数。
            await showNotice("🎙 常驻监听（后台也听）· 由小北冥请求", hold: 4.0)
            let started = await startContinuousListen()
            data = [
                "isRunning": listen.isRunning,
                "segments": listenSegments,
                "mode": "continuous",
                "format": "text",
                "sampleRate": 16000,
            ]
            if started.ok {
                data["note"] = "音频只在手机本地转写，上传的是文字；停止用 listenStop"
                if !asr.isReady(preferredModel: settings.onDeviceModel) {
                    data["asr"] = "not-ready"
                    data["asrHint"] = "模型未准备，段落会转写失败；先在设置页点「准备模型」"
                }
            } else {
                ok = false
                errorText = started.error
            }

        case "listenStop":
            let wasRunning = listen.isRunning
            stopContinuousListen()
            data = [
                "isRunning": listen.isRunning,
                "segments": listenSegments,
                "mode": "continuous",
                "stopped": wasRunning,
            ]

        default:
            ok = false
            errorText = "App 不认识这条指令：\(command.cmd)"
        }

        if notice != nil && (command.cmd == "look" || command.cmd == "listen") {
            // 采集结束后让提示按 3 秒总时长收掉
            noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_300_000_000)
                self?.notice = nil
            }
        }

        audit(cmd: command.cmd, id: command.id, ok: ok, error: errorText, data: data)
        if !ok { lastError = errorText }

        do {
            try await bridge.report(id: command.id, ok: ok, data: data, error: errorText, media: media)
        } catch {
            lastError = "结果上报失败：\(Self.short(error))"
        }
    }

    private func showNotice(_ text: String, hold: Double) async {
        noticeTask?.cancel()
        notice = text
        // 先把提示画到屏幕上，再动硬件。
        try? await Task.sleep(nanoseconds: 700_000_000)
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            self?.notice = nil
        }
    }

    // MARK: - 本地记录

    private func audit(cmd: String, id: String, ok: Bool, error: String, data: [String: Any]) {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return }
        let dir = base.appendingPathComponent("XiaoBeiMing", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("device-log.jsonl")

        var record: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "id": id,
            "cmd": cmd,
            "ok": ok,
            "error": error,
            "mode": awake ? "awake" : "standby",
            "channel": router.activeTag,
        ]
        // 只记元信息，不记媒体正文（base64 会把日志撑爆）。
        record["data"] = data.filter { !($0.value is Data) }
        guard let line = try? JSONSerialization.data(withJSONObject: record, options: []),
              var text = String(data: line, encoding: .utf8) else { return }
        text += "\n"

        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func clearLog() {
        if let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: false) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("XiaoBeiMing/device-log.jsonl"))
        }
    }

    private static func short(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let detail = localized.errorDescription { return detail }
        return error.localizedDescription
    }
}
