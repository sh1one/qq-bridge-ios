import UIKit

/// 手。只能"打开一个 App"，不能在别人的界面里点东西（那需要 WDA，见 README 第三部分）。
///
/// 两个真实边界：
/// - 未安装 / scheme 不对 → canOpenURL 返回 false，这里如实报错，不假装成功；
/// - iOS 不允许后台 App 拉起别的 App。App 在后台时 open 会被系统忽略，
///   所以只有居前台（或刚刚被唤醒）时才真的能跳转。这条写进返回值里。
@MainActor
final class OpenAppService {
    struct OpenResult {
        let opened: Bool
        let url: String
        let error: String
        let foreground: Bool
    }

    /// 常用 App 的 scheme。camera / settings 用系统私有 prefs scheme，
    /// 侧载场景可用，但不同 iOS 版本可能失效——失败会回明确错误。
    static let schemes: [String: String] = [
        "wechat": "weixin://",
        "weixin": "weixin://",
        "alipay": "alipays://",
        "zhifubao": "alipays://",
        "qq": "mqq://",
        "camera": "camera://",
        "settings": "App-Prefs:",
        "photos": "photos-redirect://",
        "shortcuts": "shortcuts://",
        "instagram": "instagram://app",
        "twitter": "twitter://",
        "x": "twitter://",
        "facebook": "fb://",
        "whatsapp": "whatsapp://",
        "music": "music://",
        "maps": "maps://",
        "weibo": "sinaweibo://",
        "bilibili": "bilibili://",
        "zhihu": "zhihu://",
        "taobao": "taobao://",
    ]

    static func resolve(app: String) -> String? {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return schemes[key]
    }

    var isForeground: Bool {
        UIApplication.shared.applicationState == .active
    }

    func open(_ target: String) async -> OpenResult {
        var raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return OpenResult(opened: false, url: target, error: "空的 URL", foreground: isForeground)
        }
        if !raw.contains("://"), !raw.hasSuffix(":"), !raw.contains(":") {
            raw = "https://\(raw)"
        }
        guard let url = URL(string: raw) else {
            return OpenResult(opened: false, url: raw, error: "URL 解析失败：\(raw)", foreground: isForeground)
        }
        // 只有 http(s) 和已声明过的 scheme 才允许问 canOpenURL，否则一律 false。
        if let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" {
            guard UIApplication.shared.canOpenURL(url) else {
                return OpenResult(opened: false,
                                  url: raw,
                                  error: "打不开：这个 App 没装，或 scheme \(scheme):// 不被系统允许（看 Info.plist 的 LSApplicationQueriesSchemes）",
                                  foreground: isForeground)
            }
        }
        if !isForeground {
            return OpenResult(opened: false,
                              url: raw,
                              error: "App 在后台，iOS 不允许后台拉起别的 App；把「小北冥」切到前台再试",
                              foreground: false)
        }
        let ok: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { success in
                cont.resume(returning: success)
            }
        }
        return OpenResult(opened: ok,
                          url: raw,
                          error: ok ? "" : "系统拒绝了这次 open（可能没装或有权限限制）",
                          foreground: true)
    }
}
