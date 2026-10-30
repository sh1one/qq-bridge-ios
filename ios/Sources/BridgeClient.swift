import Foundation

/// 桥接下发的单条指令。
struct DeviceCommand {
    let id: String
    let cmd: String
    let args: [String: Any]

    func string(_ key: String, fallback: String = "") -> String {
        if let value = args[key] as? String { return value }
        if let value = args[key] as? NSNumber { return value.stringValue }
        return fallback
    }

    func int(_ key: String, fallback: Int) -> Int {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        if let value = args[key] as? String, let parsed = Int(value) { return parsed }
        return fallback
    }

    func double(_ key: String, fallback: Double) -> Double {
        if let value = args[key] as? Double { return value }
        if let value = args[key] as? NSNumber { return value.doubleValue }
        if let value = args[key] as? String, let parsed = Double(value) { return parsed }
        return fallback
    }

    func bool(_ key: String, fallback: Bool) -> Bool {
        if let value = args[key] as? Bool { return value }
        if let value = args[key] as? NSNumber { return value.boolValue }
        if let value = args[key] as? String {
            let lowered = value.lowercased()
            if lowered == "true" || lowered == "1" { return true }
            if lowered == "false" || lowered == "0" { return false }
        }
        return fallback
    }
}

/// 心跳响应。
struct HeartbeatReply {
    let nextHeartbeatMs: Int
    let queueDepth: Int
    let deviceId: String
    let apiVersion: Int

    /// 服务端给的间隔夹到 5~60 秒，避免被异常值拖死。
    var nextInterval: TimeInterval {
        let ms = min(max(nextHeartbeatMs, 5_000), 60_000)
        return TimeInterval(ms) / 1000.0
    }
}

/// 配对的返回：设备身份 + 一次性下发的设备令牌。
struct PairReply {
    let deviceId: String
    let deviceToken: String
}

enum BridgeError: LocalizedError {
    case notConfigured
    case badResponse(String)
    case http(Int, String)
    case network(String)

    /// 鉴权类失败要靠状态码判断（401/403 说明设备令牌失效或被吊销）。
    var httpStatus: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没配置接入通道或令牌"
        case .badResponse(let detail):
            return "响应无法解析：\(detail)"
        case .http(let code, let detail):
            return "HTTP \(code)：\(detail)"
        case .network(let detail):
            return "网络错误：\(detail)"
        }
    }
}

/// 与桥接的设备接口通信。
///
/// 传输方式用 **HTTP 长轮询** 而不是 WebSocket：服务端 `/api/device/*` 的契约就是
/// poll/result + 心跳，用长轮询已经能做到"有指令立刻到"，少一层 WS 握手和重连状态机，
/// 也不受局域网代理/隧道对 WS 的支持差异影响（Cloudflare Tunnel 对 WS 是支持的，
/// 但 Tailscale + 省电休眠下长连接更容易被系统掐掉）。
///
/// 令牌两层：
///   bootstrapToken —— 配置里手填的引导令牌，只能用于探活和配对
///   deviceToken    —— 配对后服务端下发的一次性设备令牌，之后所有请求都用它
final class BridgeClient {
    var baseURL: URL?
    var bootstrapToken: String
    var deviceToken: String

    private let session: URLSession

    init(bootstrapToken: String = "", deviceToken: String = "") {
        self.bootstrapToken = bootstrapToken
        self.deviceToken = deviceToken
        // 长轮询要挂 25 秒以上，普通请求 40 秒够；不再另开 session 以免连接池抖动。
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 40
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    /// 当前该用哪个令牌：配对成功就用设备令牌，否则退回引导令牌。
    var token: String { deviceToken.isEmpty ? bootstrapToken : deviceToken }

    var configured: Bool { baseURL != nil && !token.isEmpty }

    var isPaired: Bool { !deviceToken.isEmpty }

    /// 感官通道（3102）的地址：文字事件用。
    /// http 端点固定换成 sense.port；https 隧道保持原样（反向代理可能自己映射到 3102）。
    var senseBaseURL: URL? {
        guard let base = baseURL else { return nil }
        guard base.scheme?.lowercased() == "http" else { return base }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.port = DeviceHubDefaults.sensePort
        return comps?.url ?? base
    }

    // MARK: - 底层

    private func makeURL(_ path: String, base: URL? = nil) throws -> URL {
        guard let base = base ?? baseURL, let url = URL(string: base.absoluteString + path) else {
            throw BridgeError.notConfigured
        }
        return url
    }

    private func send(path: String,
                      method: String,
                      body: [String: Any]?,
                      timeout: TimeInterval,
                      base: URL? = nil) async throws -> Any {
        let url = try makeURL(path, base: base)
        let token = self.token
        guard !token.isEmpty else { throw BridgeError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(token, forHTTPHeaderField: "x-device-token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            } catch {
                throw BridgeError.badResponse("请求体编码失败：\(error.localizedDescription)")
            }
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let error as URLError {
            throw BridgeError.network("\(error.code.rawValue) \(error.localizedDescription)")
        } catch {
            throw BridgeError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        if code != 200 {
            // 服务端错误响应也是 JSON，尽量把 code 字段带出来方便判断。
            var detail = Self.trimmedSnippet(text)
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let serverCode = obj["code"] as? String {
                detail = serverCode
            }
            throw BridgeError.http(code, detail)
        }
        guard !data.isEmpty else { return [String: Any]() }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw BridgeError.badResponse(Self.trimmedSnippet(text))
        }
        if let dict = obj as? [String: Any], (dict["ok"] as? Bool) == false {
            throw BridgeError.http(code, (dict["code"] as? String) ?? "服务端返回 ok=false")
        }
        return obj
    }

    private static func trimmedSnippet(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= 200 { return flat }
        let end = flat.index(flat.startIndex, offsetBy: 200)
        return String(flat[flat.startIndex..<end]) + "…"
    }

    // MARK: - 接口

    /// 探活，返回延迟（毫秒）。失败不抛错，交给 EndpointRouter 判定"这条不通"。
    func ping() async -> (ok: Bool, latencyMs: Int, error: String) {
        let started = Date()
        do {
            let obj = try await send(path: "/api/device/ping", method: "GET", body: nil, timeout: 3)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let dict = obj as? [String: Any]
            return ((dict?["pong"] as? Bool) == true, ms, "")
        } catch {
            return (false, Int(Date().timeIntervalSince(started) * 1000), Self.describe(error))
        }
    }

    /// 配对：服务端用引导令牌确认身份，下发一次性设备令牌。
    /// 已经配对过的设备用同一个 deviceId 再来一次是安全的（会轮换令牌）。
    func pair(deviceId: String, deviceName: String) async throws -> PairReply {
        let body: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "appVersion": Self.appVersion(),
            "mode": "awake"
        ]
        let obj = try await send(path: "/api/device/pair", method: "POST", body: body, timeout: 15)
        guard let dict = obj as? [String: Any],
              let newId = dict["deviceId"] as? String,
              let newToken = dict["deviceToken"] as? String,
              !newToken.isEmpty else {
            throw BridgeError.badResponse("配对响应缺 deviceId/deviceToken")
        }
        return PairReply(deviceId: newId, deviceToken: newToken)
    }

    /// 长轮询待执行指令。无指令时服务端挂起到超时，返回空数组。
    func poll(waitSeconds: Int = 25) async throws -> [DeviceCommand] {
        let wait = min(max(waitSeconds, 1), 30)
        let path = "/api/device/poll?wait=\(wait * 1000)"
        let obj = try await send(path: path, method: "GET", body: nil, timeout: TimeInterval(wait) + 15)
        guard let dict = obj as? [String: Any], let list = dict["commands"] as? [[String: Any]] else {
            throw BridgeError.badResponse("poll 响应缺 commands")
        }
        var out: [DeviceCommand] = []
        for item in list {
            guard let id = item["id"] as? String, let cmd = item["cmd"] as? String else { continue }
            let args = (item["args"] as? [String: Any]) ?? [:]
            out.append(DeviceCommand(id: id, cmd: cmd, args: args))
        }
        return out
    }

    /// 上报执行结果。媒体以 base64 放在 media 里，由桥接落盘。
    func report(id: String,
                ok: Bool,
                data: [String: Any],
                error: String?,
                media: (ext: String, base64: String)?) async throws {
        var body: [String: Any] = ["id": id, "ok": ok, "data": data]
        if let error = error, !error.isEmpty {
            body["error"] = error
        }
        if let media = media, !media.base64.isEmpty {
            body["media"] = ["ext": media.ext, "base64": media.base64]
        }
        _ = try await send(path: "/api/device/result", method: "POST", body: body, timeout: 30)
    }

    /// 把端上识别出的文字送进感官通道（3102）。音频不上传，这里只有文字和耗时。
    /// 失败由调用方记日志，不影响 `report` 里的兜底音频路径。
    @discardableResult
    func postUtterance(text: String,
                       ms: Int,
                       model: String,
                       durationSec: Double,
                       sessionId: String) async throws -> [String: Any] {
        guard let base = senseBaseURL else { throw BridgeError.notConfigured }
        let body: [String: Any] = [
            "text": text,
            "ms": ms,
            "model": model,
            "durationSec": durationSec,
            "source": "device",
            "sessionId": sessionId
        ]
        let obj = try await send(path: "/api/sense/utterance",
                                 method: "POST",
                                 body: body,
                                 timeout: 8,
                                 base: base)
        return (obj as? [String: Any]) ?? [:]
    }

    /// 常驻监听（CallKit）每切一段调一次：只把文字和这一段的起止时间/能量发给桥接。
    /// 走主端口 3101 的 `/api/device/speech`，而不是感官通道的 utterance：
    /// 常驻监听期间 3102 的实时音频流是停的（两个 engine 不能共存），不能再依赖它。
    @discardableResult
    func postSpeech(text: String,
                    startedAt: Date,
                    endedAt: Date,
                    rms: Double,
                    durationMs: Int) async throws -> [String: Any] {
        let body: [String: Any] = [
            "text": text,
            "startedAt": Int64((startedAt.timeIntervalSince1970 * 1000).rounded()),
            "endedAt": Int64((endedAt.timeIntervalSince1970 * 1000).rounded()),
            "rms": rms,
            "durationMs": durationMs
        ]
        let obj = try await send(path: "/api/device/speech", method: "POST", body: body, timeout: 8)
        return (obj as? [String: Any]) ?? [:]
    }

    func heartbeat(battery: Int,
                   charging: Bool,
                   mode: String,
                   deviceName: String,
                   lastError: String,
                   channels: [[String: Any]],
                   listen: [String: Any] = [:]) async throws -> HeartbeatReply {
        var body: [String: Any] = [
            "battery": battery,
            "charging": charging,
            "mode": mode,
            "deviceName": deviceName,
            "appVersion": Self.appVersion(),
            "channels": channels
        ]
        if !listen.isEmpty { body["listen"] = listen }
        if !lastError.isEmpty { body["lastError"] = lastError }
        let obj = try await send(path: "/api/device/heartbeat", method: "POST", body: body, timeout: 12)
        let dict = (obj as? [String: Any]) ?? [:]
        return HeartbeatReply(nextHeartbeatMs: (dict["nextHeartbeatMs"] as? Int) ?? 20_000,
                              queueDepth: (dict["queueDepth"] as? Int) ?? 0,
                              deviceId: (dict["deviceId"] as? String) ?? "",
                              apiVersion: (dict["apiVersion"] as? Int) ?? 0)
    }

    /// 读设备服务状态；控制台里也能看到同一份数据，这里主要给首页显示用。
    func fetchStatus() async throws -> [String: Any] {
        let obj = try await send(path: "/api/device/status", method: "GET", body: nil, timeout: 12)
        return (obj as? [String: Any]) ?? [:]
    }

    static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }

    static func describe(_ error: Error) -> String {
        if let bridge = error as? BridgeError {
            return bridge.errorDescription ?? "未知错误"
        }
        return error.localizedDescription
    }
}
