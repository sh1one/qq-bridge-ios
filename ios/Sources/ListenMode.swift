import AVFoundation
import CallKit
import Foundation

/// 常驻监听会抛的错。文案和 `MicError` 同一口径：告诉用户去哪儿开权限，而不是抛系统错误码。
enum ListenError: LocalizedError {
    case permission
    case session(String)
    case engine(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .permission:
            return "没有麦克风权限：去 设置 → 小北冥 → 麦克风 打开"
        case .session(let why):
            return "音频会话配置失败：\(why)"
        case .engine(let why):
            return "音频引擎启动失败：\(why)"
        case .notConfigured:
            return "还没有可用的接入通道或设备令牌，识别出的文字发不出去"
        }
    }
}

/// 给界面看的轻量状态。DeviceController 把它桥接成 @Published，
/// 和 `SenseStream.Snapshot` 是同一套写法：服务类不引 Combine，也不碰 SwiftUI。
struct ListenSnapshot {
    var isRunning = false
    /// 已经切出来并送去转写的段数（短于 0.6 秒被丢掉的段不计入）。
    var segments = 0
    var lastText = ""
    var lastError = ""
    /// 正在说话：界面可以显示「正在听」。
    var speaking = false
    /// 系统层面的「通话」是否已经建立（CallKit 报告成功）。
    var callActive = false
    /// 还没转写完的段数，用来观察积压。
    var pending = 0
    var lastSegmentMs = 0
    /// 用户「想要一直听」的意图（持久化）。系统重置通话后按这个决定要不要自己拉回来。
    var wants = false
}

/// 常驻监听（CallKit 版）：让 App 表现得像一通正在进行的语音通话，锁屏/后台继续用麦克风。
///
/// 为什么非要 CallKit：iOS 上「后台还能录」只有两条路——
/// 1) `UIBackgroundModes=audio` + 一直有音频在播（就是 `KeepAlive` 的静音循环）。
///    它只能让**进程**活着，锁屏后麦克风输入会被系统降优先级，`AVAudioEngine` 的输入 tap 慢慢就没数据了；
/// 2) 真处在 CallKit 的一通通话里。系统把这种会话当通话音频对待，输入轨道才持续供数。
///    所以这里两件事都做：会话先按 `.playAndRecord / .voiceChat` 配好，再 report 一通 CallKit 通话。
/// 代价和 `KeepAlive` 一样：App Store 不会允许，只走侧载。
///
/// 数据路径（音频不出手机）：
///   tap（实时线程）→ 重采样到 16 kHz 单声道 Float → stateQueue 切段
///   → 后台 Task 写临时 wav → `OnDeviceASR` 转写 → `BridgeClient` POST /api/device/speech → 删 wav
///
/// 线程模型：
/// - 实时线程（tap）只做重采样 + RMS，然后 `queue.async` 投递，禁止文件 IO / ASR / 网络；
/// - 所有可变状态都在 `queue` 上；
/// - CallKit 相关字段（provider / callUUID / callStarted）只在主线程碰，start()/stop() 与 delegate 回调都在主线程。
final class ListenMode: NSObject, CXProviderDelegate {

    /// 切段参数。默认值就是约定口径：300ms 起音 / 800ms 收尾 / 20s 硬切 / 0.6s 丢短段。
    struct Config {
        var sampleRate: Double = 16_000
        /// 连续高于阈值多久算「开始说话」。
        var onsetMs: Int = 300
        /// 说话中静音多久算「这一段结束」。
        var silenceMs: Int = 800
        /// 收尾时保留的尾部静音。全剪掉会把最后一个字的尾音削掉，留一点更稳。
        var tailKeepMs: Int = 200
        /// 单段最短时长：低于这个当咳嗽/碰撞丢掉，别拿去浪费一次转写。
        var minSegmentSec: Double = 0.6
        /// 单段最长时长：超过就硬切，否则一句话能拖到几十秒，WhisperKit 也不划算。
        var maxSegmentSec: Double = 20
        /// 人声判定阈值（线性 RMS），和 MicService / AppSettings 同一个语义。
        var threshold: Double = 0.02
    }

    /// 每次状态变化都回调（已经在主线程上）。
    var onSnapshot: ((ListenSnapshot) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    /// 全 App 只允许这一个常驻 engine（SenseStream 也自己开了一个，所以两者必须互斥）。
    private let engine = AVAudioEngine()
    /// 状态队列：tap 只往这里投递，切段、积压、错误都在这条队列上维护。
    private let queue = DispatchQueue(label: "xiaobeiming.listen")
    private let queueKey = DispatchSpecificKey<Void>()
    /// 上报用的独立客户端：不和 DeviceController 的那个抢 baseURL/令牌（它会被选路和配对改来改去）。
    private let bridge = BridgeClient()
    private let asr: OnDeviceASR
    private let callController = CXCallController()

    private var config = Config()
    private var runtime = Runtime()
    private var state = ListenSnapshot()

    // MARK: 队列内状态（只在 queue 上读写）

    private var speaking = false
    private var segmentSamples: [Float] = []
    private var segmentStartedAt = Date()
    private var segmentPeakRms: Float = 0
    private var voicedRunMs: Double = 0
    private var silenceRunMs: Double = 0
    /// 起音前的滚动尾巴：保留最近 onsetMs 的样本，说话确认后整段接上去，第一个字不会被吞。
    private var preRoll: [Float] = []
    /// 串行任务链：上一段处理完才轮到下一段（同一个 WhisperKit 实例不能并发转写）。
    private var pipeline: Task<Void, Never>?

    // MARK: 实时线程状态

    /// 只被实时线程读写：重采样要跨 buffer 做线性插值，必须记住上一个样本。
    private var lastSourceSample: Float = 0
    /// 装过 tap 才卸。没装就调 `removeTap` 在部分系统版本上会抛 ObjC 异常（不是 Swift 错误，捕不到）。
    /// 只在主线程/状态队列上读写，实时线程不碰。
    private var tapInstalled = false

    // MARK: 主线程状态（CallKit）

    private var provider: CXProvider?
    private var callUUID: UUID?
    private var callStarted = false
    private var restartScheduled = false
    private var autoRestartScheduled = false
    /// 最近几次自动重拉的时刻，用来防"重置→重拉→再重置"的死循环。
    private var autoRestartTimes: [Date] = []
    private var observers: [NSObjectProtocol] = []
    /// 「用户想要一直听」的持久化标记：真机重启/系统重置通话后靠它自己拉回来。
    private static let wantsKey = "listenWanted.v1"

    private struct Runtime {
        var baseURL: URL?
        var token = ""
        var model = OnDeviceModel.small.rawValue
    }

    private struct Segment {
        let samples: [Float]
        let sampleRate: Double
        let startedAt: Date
        let endedAt: Date
        let rms: Double
        let durationMs: Int
    }

    /// 积压上限：转写比采集慢时宁可丢，也不能让内存里的段落无限长。
    private static let maxPendingSegments = 4

    init(asr: OnDeviceASR) {
        self.asr = asr
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - 对外状态

    var isRunning: Bool { runSync { state.isRunning } }

    var snapshot: ListenSnapshot { runSync { state } }

    /// DeviceController 在选路、配对、改模型之后调用。只存值，不碰音频，随时可以调。
    func configure(baseURL: URL?, token: String, model: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.runtime.baseURL = baseURL
            self.runtime.token = token
            self.runtime.model = model
        }
    }

    // MARK: - 生命周期

    /// 起监听。返回 false 时原因在 `snapshot.lastError` 里（权限 / 会话 / 引擎）。
    @discardableResult
    func start(config newConfig: Config? = nil) -> Bool {
        if isRunning { return true }
        // 一旦起过就记住「用户想一直听」，系统重置通话后才能自己拉回来。
        UserDefaults.standard.set(true, forKey: Self.wantsKey)
        runSync { self.state.wants = true }
        guard hasPermission() else {
            fail(ListenError.permission)
            return false
        }
        if let newConfig {
            runSync { self.config = newConfig }
        }
        do {
            try activateSession()
        } catch {
            fail(ListenError.session(error.localizedDescription))
            return false
        }
        runSync {
            // 每次 start 都从干净状态开始：上一次可能是异常退出（被系统杀/引擎崩）留下的残状态。
            self.state.isRunning = true
            self.state.segments = 0
            self.state.lastText = ""
            self.state.lastError = ""
            self.state.pending = 0
            self.state.lastSegmentMs = 0
            self.resetSegmentState()
            self.pipeline?.cancel()
            self.pipeline = nil
        }
        // 顺序有意为之：先让系统认为在通话，再起引擎。反过来的话引擎拿到的输入格式
        // 可能还是通话前的（48kHz 立体声），CallKit 一切换就得重装 tap。
        startCall()
        do {
            try startCapture()
        } catch {
            endCall()
            stopCapture()
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            runSync {
                self.state.isRunning = false
                self.state.callActive = false
            }
            emit()
            fail(ListenError.engine(error.localizedDescription))
            return false
        }
        installObservers()
        emit()
        print("[LISTEN] started")
        return true
    }

    /// 停监听并彻底释放：关 tap、停引擎、断 CallKit、清积压。
    /// 幂等：CallKit 的 didDeactivate / 结束回调也会走进来，`isRunning` 已经是 false 时直接返回。
    func stop() {
        let wasRunning = runSync { () -> Bool in
            let was = self.state.isRunning
            self.state.isRunning = false
            self.state.callActive = false
            self.state.pending = 0
            self.resetSegmentState()
            self.pipeline?.cancel()
            self.pipeline = nil
            return was
        }
        guard wasRunning else { return }
        removeObservers()
        // 先断 CallKit，再放音频会话：反过来的话系统可能把刚释放的会话重新激活给这通"通话"。
        endCall()
        stopCapture()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        emit()
        print("[LISTEN] stopped")
    }

    /// 用户主动在设置页关掉：连「想听」的意图一起清掉，之后系统再重置也不会自己拉起。
    func stopByUser() {
        UserDefaults.standard.set(false, forKey: Self.wantsKey)
        runSync { self.state.wants = false }
        stop()
    }

    private func resetSegmentState() {
        speaking = false
        segmentSamples = []
        segmentPeakRms = 0
        voicedRunMs = 0
        silenceRunMs = 0
        preRoll = []
        state.speaking = false
    }

    // MARK: - 音频会话

    /// `.voiceChat + .mixWithOthers` 在部分机型/外接音频设备上会被拒，所以退两级：
    /// 先按约定配，拒了就只保留蓝牙，再不行就裸配置——录音本身比混音重要。
    private func activateSession() throws {
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.mixWithOthers, .allowBluetooth])
        } catch {
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            } catch {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            }
        }
        try session.setActive(true, options: [])
        try? session.setPreferredIOBufferDuration(0.02)
    }

    private func hasPermission() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    // MARK: - 采集

    /// 装 tap 并起引擎。start / 中断恢复 / 路由变化都走这一条路径，避免各写一套。
    private func startCapture() throws {
        if engine.isRunning { engine.stop() }
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ListenError.engine("拿不到麦克风输入格式")
        }
        // 采样率在装 tap 时就固定进闭包：重装之后老回调不会用新采样率算时长。
        let sourceRate = format.sampleRate
        lastSourceSample = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer, sourceRate: sourceRate)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func stopCapture() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        lastSourceSample = 0
    }

    /// 实时线程：只做重采样 + RMS，然后投递。这里绝对不能有文件 IO / ASR / 网络。
    private func handleTap(_ buffer: AVAudioPCMBuffer, sourceRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let target = config.sampleRate
        guard count > 0, sourceRate > 0, target > 0 else { return }
        let ratio = sourceRate / target
        let outCount = max(1, Int(Double(count) / ratio))
        var out = [Float](repeating: 0, count: outCount)
        var sum: Double = 0
        var previous = lastSourceSample
        for i in 0..<outCount {
            let position = Double(i) * ratio
            let base = Int(position)
            let fraction = Float(position - Double(base))
            let a = base < count ? channel[base] : previous
            let b = base + 1 < count ? channel[base + 1] : a
            let value = a + (b - a) * fraction
            previous = value
            sum += Double(value) * Double(value)
            out[i] = value
        }
        lastSourceSample = previous
        let rms = Float(sqrt(sum / Double(outCount)))
        queue.async { [weak self] in
            self?.ingest(out, rms: rms)
        }
    }

    // MARK: - 切段状态机

    /// 串行队列。所有时长都按「实际帧长」累加，不假设固定 buffer 大小（48k 时一帧 42ms，16k 时 128ms）。
    private func ingest(_ samples: [Float], rms: Float) {
        guard state.isRunning, !samples.isEmpty else { return }
        let frameMs = Double(samples.count) / config.sampleRate * 1000
        let voiced = Double(rms) >= config.threshold

        if !speaking {
            preRoll.append(contentsOf: samples)
            let limit = Int(config.sampleRate * Double(config.onsetMs) / 1000)
            if preRoll.count > limit {
                preRoll.removeFirst(preRoll.count - limit)
            }
            if voiced {
                voicedRunMs += frameMs
                if voicedRunMs >= Double(config.onsetMs) {
                    // 起音确认：pre-roll 里正好含这 300ms，整段当作开头，第一个字不会被吞。
                    speaking = true
                    silenceRunMs = 0
                    segmentPeakRms = rms
                    segmentSamples = preRoll
                    segmentStartedAt = Date().addingTimeInterval(-Double(preRoll.count) / config.sampleRate)
                    preRoll = []
                    state.speaking = true
                    emit()
                }
            } else {
                voicedRunMs = 0
            }
            return
        }

        segmentSamples.append(contentsOf: samples)
        segmentPeakRms = max(segmentPeakRms, rms)
        silenceRunMs = voiced ? 0 : silenceRunMs + frameMs

        if segmentSamples.count >= Int(config.sampleRate * config.maxSegmentSec) {
            // 20 秒硬切：故意不重置 speaking，下一帧直接进新段。
            // 否则会再等 300ms 起音确认，硬切点之后的话就被丢了。
            flush(forced: true)
            return
        }
        if silenceRunMs >= Double(config.silenceMs) {
            flush(forced: false)
        }
    }

    /// 落一段。`forced` = 撞到 20 秒上限被硬切，此时不剪尾巴、也不结束「说话中」状态。
    private func flush(forced: Bool) {
        var samples = segmentSamples
        if !forced {
            // 剪掉收尾静音，只留 tailKeepMs：wav 贴着最后一个字结束，转写不用消化 0.8 秒空白。
            let dropMs = max(0, config.silenceMs - config.tailKeepMs)
            let drop = min(samples.count, Int(config.sampleRate * Double(dropMs) / 1000))
            if drop > 0 { samples.removeLast(drop) }
        }
        let durationSec = Double(samples.count) / config.sampleRate
        let startedAt = segmentStartedAt
        let peak = segmentPeakRms
        let endedAt = startedAt.addingTimeInterval(durationSec)

        segmentSamples = []
        segmentPeakRms = 0
        voicedRunMs = 0
        silenceRunMs = 0
        if forced {
            // 硬切：从这个时刻重新计时，接着说话的内容进下一段。
            segmentStartedAt = Date()
        } else {
            speaking = false
            preRoll = []
            state.speaking = false
        }

        // 太短（咳嗽/碰撞/半个字）或整体偏静：丢掉，不浪费一次转写。
        guard durationSec >= config.minSegmentSec else { return }
        guard peak >= Float(config.threshold) else { return }
        enqueue(Segment(samples: samples,
                        sampleRate: config.sampleRate,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        rms: Double(peak).rounded(toPlaces: 4),
                        durationMs: Int((durationSec * 1000).rounded())))
    }

    // MARK: - 转写与上报

    private func enqueue(_ segment: Segment) {
        state.segments += 1
        state.lastSegmentMs = segment.durationMs
        guard state.pending < Self.maxPendingSegments else {
            // 积压说明手机忙不过来：丢这一段，而不是让内存和延迟一起涨。
            state.lastError = "转写积压（\(state.pending) 段），已丢弃一段"
            emit()
            return
        }
        state.pending += 1
        emit()

        let previous = pipeline
        pipeline = Task { [weak self] in
            // 串行：上一段处理完再开始这一段。同一个 WhisperKit 实例并发调用会崩。
            await previous?.value
            guard let self else { return }
            await self.process(segment)
        }
    }

    /// 后台任务：写 wav → 转写 → 上报 → 删文件。任何一步失败都只记日志，不影响下一段。
    private func process(_ segment: Segment) async {
        if Task.isCancelled {
            finish(error: "")
            return
        }
        let text: String
        do {
            text = try await transcribe(segment)
        } catch {
            let detail = Self.describe(error)
            print("[LISTEN] transcribe failed: \(detail)")
            finish(error: "这一段转写失败（已丢弃）：\(detail)")
            return
        }
        guard !text.isEmpty else {
            // 模型判定这段没有人声（noSpeechThreshold）：不是错误，但界面上别留着上一条错误。
            finish(error: "")
            return
        }
        do {
            try await post(segment, text: text)
        } catch {
            // 网络断：这一段直接丢，不重试——重试只会把下一段堵在队列里。
            let detail = Self.describe(error)
            print("[LISTEN] post failed: \(detail)")
            finish(error: "上报失败（已丢弃该段）：\(detail)")
            return
        }
        print(String(format: "[LISTEN] seg %dms rms=%.3f chars=%d", segment.durationMs, segment.rms, text.count))
        finish(text: text, error: "")
    }

    private func transcribe(_ segment: Segment) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-\(UUID().uuidString.prefix(8)).wav")
        // 无论成功失败都删：常驻监听一天能切上千段，临时文件漏了会吃满空间。
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Self.wavData(samples: segment.samples, sampleRate: segment.sampleRate)
        try data.write(to: url, options: .atomic)
        let runtime = runSync { self.runtime }
        let text = try await asr.transcribeSegment(at: url, preferredModel: runtime.model)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func post(_ segment: Segment, text: String) async throws {
        let runtime = runSync { self.runtime }
        guard let base = runtime.baseURL, !runtime.token.isEmpty else {
            throw ListenError.notConfigured
        }
        // 只有在转写链上（串行）才碰这个 client，所以这几个赋值不需要额外加锁。
        bridge.baseURL = base
        bridge.bootstrapToken = runtime.token
        bridge.deviceToken = ""
        _ = try await bridge.postSpeech(text: text,
                                        startedAt: segment.startedAt,
                                        endedAt: segment.endedAt,
                                        rms: segment.rms,
                                        durationMs: segment.durationMs)
    }

    private func finish(text: String? = nil, error: String) {
        update { snapshot in
            if let text { snapshot.lastText = text }
            snapshot.lastError = error
            snapshot.pending = max(0, snapshot.pending - 1)
        }
    }

    // MARK: - CallKit

    /// 让系统进入「通话中」。这是后台持续收音的关键：CallKit 通话里的音频会话有通话优先级，
    /// 锁屏/切后台时系统不会像对普通 App 那样把输入掐掉。
    private func startCall() {
        let configuration = CXProviderConfiguration(localizedName: "小北冥")
        // .generic 是唯一不需要电话号码/邮箱的 handle 类型。
        configuration.supportedHandleTypes = [.generic]
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        // 别往系统通话记录里塞一条假记录：用户会以为真有人打过电话。
        configuration.includesCallsInRecents = false

        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)   // nil = 主队列回调，界面状态好同步
        self.provider = provider

        let uuid = UUID()
        callUUID = uuid
        let handle = CXHandle(type: .generic, value: "小北冥")
        let action = CXStartCallAction(call: uuid, handle: handle)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            guard let self else { return }
            if let error {
                // 起通话失败不致命：音频会话还在，前台/亮屏照样能听，只是后台可能被系统掐。
                self.report(error: "CallKit 起通话失败（后台可能被系统掐断）：\(error.localizedDescription)")
                return
            }
            self.callStarted = true
            self.update { $0.callActive = true }
        }
    }

    private func endCall() {
        guard let provider else { return }
        if callStarted, let uuid = callUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        callStarted = false
        callUUID = nil
        provider.setDelegate(nil, queue: nil)
        // 不立刻 invalidate：reportCall 是异步进系统的，紧跟着销毁 provider 有概率把它丢在半路，
        // 通话界面会留一条挂不掉的假通话。等它落地再释放；这期间新建 provider 不冲突。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            provider.invalidate()
        }
        self.provider = nil
    }

    /// CallKit 接管后系统会把会话换成通话配置，这里再确认一次（失败只记日志，不中断监听）。
    private func configureSessionForCall() {
        do {
            try activateSession()
        } catch {
            report(error: "通话音频会话配置失败：\(Self.describe(error))")
        }
    }

    /// 会话被系统动过之后重建采集：停引擎 → 卸 tap → 按新格式重装 → 起引擎。
    /// 留一点延迟是因为刚切换完路由时输入格式还在跳，立刻装 tap 会拿不到数据。
    private func restartCaptureSoon(reason: String, delay: TimeInterval) {
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            guard self.isRunning else { return }
            do {
                try self.activateSession()
                try self.startCapture()
                print("[LISTEN] capture restarted (\(reason))")
            } catch {
                self.report(error: "\(reason)后恢复采集失败：\(Self.describe(error))")
            }
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        // 系统把通话状态清了（重启、权限被撤销等）：先自己收尾，否则会留下一个半死的 engine。
        // 如果用户本来就想要「一直听」，收尾之后自动再拉一次——熄屏/后台也走这条路。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wants = self.isWanted
            self.report(error: wants ? "系统重置了通话状态，正在自动恢复常驻监听" : "系统重置了通话状态，常驻监听已停止")
            self.stop()
            if wants { self.scheduleAutoRestart() }
        }
    }

    /// 「用户想听」的口径：内存状态与持久化标记任一为真即算（防止刚启动时状态还没同步）。
    private var isWanted: Bool {
        runSync { self.state.wants } || UserDefaults.standard.bool(forKey: Self.wantsKey)
    }

    /// 被系统收走通话后自己拉回来。延迟 1.5 秒是给 CallKit 和音频会话留落定时间：
    /// 立刻再 report 一通，很容易触发第二次重置（真机上试过）。
    /// 五分钟里连着重置 5 次就停手，否则会陷入"重置→重拉→再重置"的死循环，白耗电还吵。
    private func scheduleAutoRestart() {
        guard !autoRestartScheduled else { return }
        let now = Date()
        autoRestartTimes = autoRestartTimes.filter { now.timeIntervalSince($0) < 300 }
        guard autoRestartTimes.count < 5 else {
            report(error: "通话反复被系统重置（5 分钟内 \(autoRestartTimes.count) 次），已停止尝试；请重新打开常驻监听")
            UserDefaults.standard.set(false, forKey: Self.wantsKey)
            runSync { self.state.wants = false }
            return
        }
        autoRestartTimes.append(now)
        autoRestartScheduled = true
        print("[LISTEN] 计划自动恢复")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.autoRestartScheduled = false
            guard self.isWanted, !self.isRunning else { return }
            guard self.hasPermission() else {
                self.report(error: "自动恢复失败：麦克风权限已失效")
                return
            }
            if self.start() {
                print("[LISTEN] 已自动恢复")
            } else {
                let reason = self.snapshot.lastError
                self.report(error: "自动恢复失败：\(reason.isEmpty ? "未知原因" : reason)")
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // 我们自己发起的外呼：那通「通话」在这里正式成立。
        configureSessionForCall()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
        action.fulfill()
        callStarted = true
        update { $0.callActive = true }
        // 拿到通话之后把采集重新拉起：CallKit 可能已经按通话配置改过采样率。
        restartCaptureSoon(reason: "通话建立", delay: 0.15)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        // 先清掉 callStarted，避免 stop() 里再 report 一次结束。
        callStarted = false
        stop()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // 没有走 reportNewIncomingCall，正常不会来；实现了是为了别让 CallKit 卡在响铃状态。
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // 系统把会话交给这通通话：必须自己 setActive，否则引擎拿不到输入。
        try? audioSession.setActive(true, options: [])
        restartCaptureSoon(reason: "通话音频激活", delay: 0.15)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // 通话被系统收回（用户挂断、别处接听）：采集没法继续，直接收尾。
        guard isRunning else { return }
        report(error: "通话已被系统结束，常驻监听停止")
        stop()
    }

    // MARK: - 系统事件

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                           object: nil,
                                           queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                           object: nil,
                                           queue: .main) { [weak self] _ in
            self?.restartCaptureSoon(reason: "音频服务重启", delay: 1.0)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                           object: nil,
                                           queue: .main) { [weak self] _ in
            self?.restartCaptureSoon(reason: "音频路由变化", delay: 0.4)
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // 麦克风被系统抢走（来电、闹钟、别的通话）：等它结束再恢复，别在这里硬抢。
            update { $0.lastError = "麦克风被系统临时收回（来电/闹钟），结束后会自动恢复" }
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                restartCaptureSoon(reason: "中断结束", delay: 0.4)
            } else {
                update { $0.lastError = "中断结束但系统没给恢复许可，需要重新打开常驻监听" }
            }
        @unknown default:
            restartCaptureSoon(reason: "未知中断", delay: 1.0)
        }
    }

    // MARK: - 状态

    private func fail(_ error: Error) {
        report(error: Self.describe(error))
        runSync { self.state.isRunning = false }
        emit()
    }

    private func report(error message: String) {
        update { $0.lastError = message }
        print("[LISTEN] \(message)")
    }

    /// 在任意线程安全地改状态：队列内直接改，队列外投递（关掉时保证界面能看到最后一次变化）。
    private func update(_ mutate: @escaping (inout ListenSnapshot) -> Void) {
        if onQueue {
            mutate(&state)
            emit()
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            mutate(&self.state)
            self.emit()
        }
    }

    private func emit() {
        let current = runSync { state }
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(current)
        }
    }

    private var onQueue: Bool { DispatchQueue.getSpecific(key: queueKey) != nil }

    /// 队列内直接调用，队列外 sync 进来；这样同一个方法在两种上下文都能用而不会自锁。
    private func runSync<T>(_ block: () throws -> T) rethrows -> T {
        if onQueue { return try block() }
        return try queue.sync(execute: block)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    // MARK: - wav

    /// 16 kHz / 单声道 / 16 bit PCM 的 wav。WhisperKit 只吃文件路径，所以每段都得先落一次盘。
    /// 头部 44 字节手写：Foundation 没有"把 Float 数组写成 PCM16 wav"的现成 API，
    /// 引 AVAssetWriter 又比写 44 字节重得多（而且它在后台容易被系统判定为编码任务）。
    private static func wavData(samples: [Float], sampleRate: Double) -> Data {
        let rate = Int(sampleRate.rounded())
        let channels = 1
        let bits = 16
        let byteRate = rate * channels * bits / 8
        let blockAlign = channels * bits / 8
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, value) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, Double(value)))
            pcm[index] = Int16(clamped * 32767.0)
        }

        var data = Data(capacity: 44 + pcm.count * 2)
        func appendASCII(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        func appendUInt16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + pcm.count * 2))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                  // fmt 块长度
        appendUInt16(1)                   // 1 = PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(rate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bits))
        appendASCII("data")
        appendUInt32(UInt32(pcm.count * 2))
        pcm.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            data.append(Data(bytes: base, count: raw.count * MemoryLayout<Int16>.size))
        }
        return data
    }
}
