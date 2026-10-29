import Foundation

/// 端上识别可选的 WhisperKit 模型。
///
/// 体积是权重文件的实际大小（HF `argmaxinc/whisperkit-coreml`），不含 tokenizer：
/// tiny ≈ 76 MB、base ≈ 146 MB、small ≈ 484 MB。默认 small：中文准确率明显好于 base，
/// A15 上 2 秒音频的目标是 ≤1.2 秒（首次加载/预编译会慢，之后才是这个量级）。
enum OnDeviceModel: String, CaseIterable, Identifiable {
    case tiny
    case base
    case small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "tiny · 76 MB"
        case .base: return "base · 146 MB"
        case .small: return "small · 484 MB（默认）"
        }
    }

    var shortName: String { rawValue }

    static func normalized(_ raw: String) -> OnDeviceModel {
        OnDeviceModel(rawValue: raw) ?? .small
    }
}

/// App 自己的设置（和桥接地址分开存，避免保存网络配置时把 ASR 开关冲掉）。
struct AppSettings: Codable, Equatable {
    /// 默认开启：识别在手机本地完成，只把文字发给桥接。
    var useOnDeviceASR: Bool = true
    /// WhisperKit 模型名：tiny / base / small。
    var onDeviceModel: String = OnDeviceModel.small.rawValue
    /// 说完后静音多久收尾（毫秒）。800~1000 是实测比较顺手的区间。
    var vadSilenceMs: Int = 800
    /// 人声判定阈值（线性 RMS）。安静房间 0.015~0.03 都合理。
    var vadThreshold: Double = 0.02

    var model: OnDeviceModel { OnDeviceModel.normalized(onDeviceModel) }
    var vadSilenceSeconds: Double { Double(vadSilenceMs) / 1000.0 }

    static let storageKey = "app.settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        var settings = decoded
        settings.vadSilenceMs = max(200, min(3000, settings.vadSilenceMs))
        settings.vadThreshold = max(0.005, min(0.2, settings.vadThreshold))
        if OnDeviceModel(rawValue: settings.onDeviceModel) == nil {
            settings.onDeviceModel = OnDeviceModel.small.rawValue
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AppSettings.storageKey)
    }
}
