import Combine
import CoreML
import Foundation
import WhisperKit

/// 端上识别的一次结果。`ms` 只统计算术推理，不含模型下载/加载。
struct ASRResult {
    let text: String
    let ms: Int
    let model: String
}

/// 给界面看的轻量状态（DeviceController 会转成 @Published，避免把 WhisperKit 塞进 SwiftUI）。
struct ASRState {
    var isPreparing: Bool = false
    var progress: Double = 0
    var status: String = "未加载"
    var model: String = ""
    var lastError: String = ""
    var lastMs: Int?
}

enum ASRError: LocalizedError {
    case notReady
    case modelIncomplete(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "端上识别模型还没准备好"
        case .modelIncomplete(let name):
            return "模型文件不完整：\(name)"
        case .loadFailed(let why):
            return "端上识别模型加载失败：\(why)"
        }
    }
}

/// A15 神经引擎上的本地 ASR：WhisperKit + CoreML，音频不出手机。
///
/// 设计取舍：
/// - 模型显式下载到 `Application Support/XiaoBeiMing/Models`，进度能显示，也能被系统备份策略排除；
/// - `audioEncoderCompute` / `textDecoderCompute` 显式指到 `.cpuAndNeuralEngine`：
///   iOS 16 上 WhisperKit 的默认 encoder 是 `.cpuAndGPU`，不写这一行就吃不到神经引擎；
/// - 加载失败按「请求的模型 → base → tiny」回退，回退成功也把实际模型名带回去；
/// - 第一次加载会做 CoreML 预编译（`prewarm`），可能几十秒；之后 2 秒音频的目标是 ≤1.2 秒。
@MainActor
final class OnDeviceASR {
    /// 每次状态变化都回调；DeviceController 用它刷新设置页。
    var onUpdate: ((ASRState) -> Void)?

    private(set) var state = ASRState()
    private var kit: WhisperKit?
    private var loadedModel = ""
    /// 转写互斥闸门。`@MainActor` 只能保证同步段不并发，`await kit.transcribe` 期间会重新入队，
    /// 于是「桥接下发的 listen」和「常驻监听的段落」完全可能同时进同一个 kit —— 那会直接崩，
    /// 所以必须有一道真正的串行闸门（见文件末尾的 `TranscriptionGate`）。
    private let gate = TranscriptionGate()

    private let fileManager = FileManager.default

    /// `Application Support/XiaoBeiMing/Models`。WhisperKit 会在下面建 `models/<repo>/...`。
    private var modelsBase: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("XiaoBeiMing", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private func modelFolder(_ variant: String) -> URL {
        modelsBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    private func isModelComplete(_ folder: URL) -> Bool {
        let needed = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return needed.allSatisfy {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// 回退顺序：用户选的优先，然后 base、tiny；去重，不重复加载同一个。
    private static func fallbackOrder(_ preferred: String) -> [String] {
        var order: [String] = []
        for name in [preferred, "base", "tiny"] where !name.isEmpty && !order.contains(name) {
            order.append(name)
        }
        return order
    }

    /// 是否已经有可用模型。没准备好时 listen 不走端上，避免在指令里等几百 MB 下载。
    /// 注意：这里不要求「首选模型」——small 加载失败后已经回退到 base/tiny 时，
    /// 也应该直接用已加载的模型，而不是每次 listen 都判成 not-ready。
    func isReady(preferredModel: String) -> Bool {
        _ = preferredModel
        return kit != nil
    }

    /// 设置页「准备模型」：只加载，不转写。返回是否成功（失败时 state.lastError 有原因）。
    @discardableResult
    func prepare(preferredModel: String) async -> Bool {
        // 和转写抢同一道闸门：模型加载和转写同时进 WhisperKit 同样会出问题。
        await gate.acquire()
        do {
            _ = try await ensureReady(preferredModel: preferredModel)
            await gate.release()
            return true
        } catch {
            update {
                $0.isPreparing = false
                $0.lastError = Self.describe(error)
                $0.status = "准备失败：\(Self.short(error))"
            }
            await gate.release()
            return false
        }
    }

    /// 转写一段 16 kHz 单声道 wav。失败会抛错，由调用方决定是否回退上传音频。
    func transcribe(wavURL: URL, durationSec: Double, preferredModel: String) async throws -> ASRResult {
        await gate.acquire()
        do {
            let result = try await transcribeLocked(wavURL: wavURL,
                                                    durationSec: durationSec,
                                                    preferredModel: preferredModel)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// 常驻监听用的「一段一转写」入口。返回去掉首尾空白的文本。
    ///
    /// 和 `transcribe` 只差一件事，但很要命：**绝不下载模型**。常驻监听在后台每隔几秒调一次，
    /// 这里一旦触发 `WhisperKit.download`，用户会在不知情时被吃掉几百 MB 流量、电池也扛不住；
    /// 模型没准备好就抛错，由上层记一条 lastError，等用户点「准备模型」。
    func transcribeSegment(at url: URL,
                           preferredModel: String = OnDeviceModel.small.rawValue) async throws -> String {
        await gate.acquire()
        do {
            let text = try await transcribeSegmentLocked(at: url, preferredModel: preferredModel)
            await gate.release()
            return text
        } catch {
            // 后台每隔几秒就会调一次，失败绝不能把「准备中」残留在界面上：
            // 设置页的「准备模型」按钮正是按 asrState.isPreparing 置灰的。
            update { $0.isPreparing = false }
            await gate.release()
            throw error
        }
    }

    private func transcribeLocked(wavURL: URL, durationSec: Double, preferredModel: String) async throws -> ASRResult {
        // listen 里不做模型升级：确保有模型可用即可，换模型由设置页「准备模型」负责。
        if kit == nil {
            _ = try await ensureReady(preferredModel: preferredModel)
        }
        guard let kit else { throw ASRError.notReady }
        let model = loadedModel
        let startedAt = Date()
        let results = try await kit.transcribe(audioPath: wavURL.path, decodeOptions: transcriptOptions)
        let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        publishReady(model: model, ms: ms)
        // 耗时日志：用 Xcode 控制台/Console.app 搜 "[ASR]" 就能拿到真机数据。
        print(String(format: "[ASR] model=%@ audio=%.2fs stt=%dms chars=%d",
                     model, durationSec, ms, text.count))
        return ASRResult(text: text, ms: ms, model: model)
    }

    private func transcribeSegmentLocked(at url: URL, preferredModel: String) async throws -> String {
        // 已经被 prepare 加载过就直接用，省掉一次 ensureReady 的模型名比较（常驻监听每段都会调）。
        if kit == nil {
            _ = try await ensureReady(preferredModel: preferredModel, allowDownload: false)
        }
        guard let kit else { throw ASRError.notReady }
        let model = loadedModel
        let startedAt = Date()
        let results = try await kit.transcribe(audioPath: url.path, decodeOptions: transcriptOptions)
        let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        publishReady(model: model, ms: ms)
        print(String(format: "[ASR] segment model=%@ stt=%dms chars=%d", model, ms, text.count))
        return text
    }

    /// 两条路径共用的解码参数：中文、贪心解码（temperature 0）、不要时间戳。
    private var transcriptOptions: DecodingOptions {
        DecodingOptions(
            language: "zh",
            temperature: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            noSpeechThreshold: 0.6
        )
    }

    private func publishReady(model: String, ms: Int) {
        update {
            $0.isPreparing = false
            $0.progress = 1
            $0.model = model
            $0.status = "已就绪 · \(model)"
            $0.lastError = ""
            $0.lastMs = ms
        }
    }

    private func ensureReady(preferredModel: String, allowDownload: Bool = true) async throws -> String {
        let preferred = OnDeviceModel.normalized(preferredModel).rawValue
        if kit != nil, loadedModel == preferred { return loadedModel }

        var lastError: Error?
        for variant in Self.fallbackOrder(preferred) {
            do {
                try await load(variant, allowDownload: allowDownload)
                loadedModel = variant
                update {
                    $0.isPreparing = false
                    $0.progress = 1
                    $0.model = variant
                    $0.status = "已就绪 · \(variant)"
                    $0.lastError = variant == preferred ? "" : "\(preferred) 不可用，已回退 \(variant)"
                }
                if variant != preferred {
                    print("[ASR] \(preferred) 加载失败，已回退 \(variant)：\(Self.describe(lastError))")
                }
                return variant
            } catch {
                lastError = error
                print("[ASR] \(variant) 加载失败：\(Self.describe(error))")
                // 同一个 kit 可能只加载了一半，先释放再试下一个。
                kit = nil
                loadedModel = ""
            }
        }
        throw ASRError.loadFailed(Self.describe(lastError))
    }

    private func load(_ variant: String, allowDownload: Bool = true) async throws {
        update {
            $0.isPreparing = true
            $0.progress = 0
            $0.model = variant
            $0.status = "检查 \(variant) 模型…"
        }
        try fileManager.createDirectory(at: modelsBase, withIntermediateDirectories: true)

        let folder = modelFolder(variant)
        let modelFolder: URL
        if isModelComplete(folder) {
            modelFolder = folder
            update { $0.status = "已缓存 \(variant)，加载中…"; $0.progress = 0.3 }
        } else if allowDownload {
            update { $0.status = "下载 \(variant)…"; $0.progress = 0 }
            // 约 76/146/484 MB；Progress 是 URLSession 的下载进度。
            modelFolder = try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsBase
            ) { progress in
                let fraction = max(0, min(1, progress.fractionCompleted))
                DispatchQueue.main.async { [weak self] in
                    self?.update {
                        $0.progress = fraction
                        $0.status = "下载 \(variant) \(Int(fraction * 100))%"
                    }
                }
            }
        } else {
            // 常驻监听走的路径：只认本地已经下好的模型。缺了就让上层显示「模型没准备」，
            // 后台悄悄下几百 MB 是比「转写失败」更糟的结果。
            // 这里必须把 isPreparing 收回 false：它是设置页「准备模型」按钮的置灰条件，
            // 留在 true 会让用户明明没在下模型、按钮却点不动。
            update {
                $0.isPreparing = false
                $0.status = "还没有 \(variant) 模型（要下载请点「准备模型」）"
                $0.lastError = "模型未准备：\(variant)"
            }
            throw ASRError.modelIncomplete(variant)
        }
        guard isModelComplete(modelFolder) else {
            throw ASRError.modelIncomplete(modelFolder.lastPathComponent)
        }

        update { $0.status = "加载 \(variant) 到神经引擎…"; $0.progress = max(0.35, $0.progress) }
        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine,
            prefillCompute: .cpuOnly
        )
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelsBase,
            computeOptions: compute,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let startedAt = Date()
        kit = try await WhisperKit(config)
        print(String(format: "[ASR] load model=%@ %.1fs", variant, Date().timeIntervalSince(startedAt)))
    }

    private func update(_ mutate: (inout ASRState) -> Void) {
        mutate(&state)
        onUpdate?(state)
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "未知错误" }
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    private static func short(_ error: Error) -> String {
        let text = describe(error)
        return text.count <= 80 ? text : String(text.prefix(80)) + "…"
    }
}

/// 一次只放过一个「进 WhisperKit」的调用。
///
/// 为什么不用 `actor OnDeviceASR`：模型加载要驱动 CoreML、还要往主线程回进度，把整个类搬进
/// actor 会连带改掉 DeviceController 里所有调用点；这里只需要一个纯粹的互斥量，
/// 用 actor 实现最小：状态 (busy/waiters) 只会被 actor 自己改，天然无锁无竞态。
private actor TranscriptionGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        // 挂起排队。注意 `withCheckedContinuation` 的闭包是同步执行的，
        // 所以「判断 busy」和「入队」之间不会被其他调用插进来。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// 交还时直接把所有权转给下一个等待者：若先置 busy=false 再唤醒对方，
    /// 中间新建的调用可能抢先拿到闸门，把排队的人饿死。
    func release() {
        if waiters.isEmpty {
            busy = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
