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

    /// 指定模型是否已经加载好。没准备好时 listen 不走端上，避免在指令里等几百 MB 下载。
    func isReady(preferredModel: String) -> Bool {
        let preferred = OnDeviceModel.normalized(preferredModel).rawValue
        return kit != nil && loadedModel == preferred
    }

    /// 设置页「准备模型」：只加载，不转写。返回是否成功（失败时 state.lastError 有原因）。
    @discardableResult
    func prepare(preferredModel: String) async -> Bool {
        do {
            _ = try await ensureReady(preferredModel: preferredModel)
            return true
        } catch {
            update {
                $0.isPreparing = false
                $0.lastError = Self.describe(error)
                $0.status = "准备失败：\(Self.short(error))"
            }
            return false
        }
    }

    /// 转写一段 16 kHz 单声道 wav。失败会抛错，由调用方决定是否回退上传音频。
    func transcribe(wavURL: URL, durationSec: Double, preferredModel: String) async throws -> ASRResult {
        let model = try await ensureReady(preferredModel: preferredModel)
        guard let kit else { throw ASRError.notReady }
        let startedAt = Date()
        let options = DecodingOptions(
            language: "zh",
            temperature: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            noSpeechThreshold: 0.6
        )
        let results = try await kit.transcribe(audioPath: wavURL.path, decodeOptions: options)
        let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        update {
            $0.isPreparing = false
            $0.progress = 1
            $0.model = model
            $0.status = "已就绪 · \(model)"
            $0.lastError = ""
            $0.lastMs = ms
        }
        // 耗时日志：用 Xcode 控制台/Console.app 搜 "[ASR]" 就能拿到真机数据。
        print(String(format: "[ASR] model=%@ audio=%.2fs stt=%dms chars=%d",
                     model, durationSec, ms, text.count))
        return ASRResult(text: text, ms: ms, model: model)
    }

    private func ensureReady(preferredModel: String) async throws -> String {
        let preferred = OnDeviceModel.normalized(preferredModel).rawValue
        if kit != nil, loadedModel == preferred { return loadedModel }

        var lastError: Error?
        for variant in Self.fallbackOrder(preferred) {
            do {
                try await load(variant)
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

    private func load(_ variant: String) async throws {
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
        } else {
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
