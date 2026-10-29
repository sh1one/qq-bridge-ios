import Foundation

/// 一条接入通道。
///
/// tag 约定三种（只用于界面显示和排查，不参与鉴权）：
///   lan       —— 家里 WiFi 直连，最快，出门就用不了
///   tailscale —— Tailscale 100.x 地址，不开公网端口，出门首选
///   tunnel    —— Cloudflare Tunnel 之类的 HTTPS 域名，最后兜底
struct BridgeEndpoint: Codable, Equatable, Identifiable, Sendable {
    var tag: String
    var url: String

    var id: String { tag }

    var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 把配置项解析成 base URL（去掉 path/query），http 且没写端口时补 3101。
    func baseURL() -> URL? {
        guard !trimmed.isEmpty else { return nil }
        var text = trimmed
        if !text.contains("://") { text = "http://" + text }
        guard var comps = URLComponents(string: text) else { return nil }
        let scheme = (comps.scheme ?? "http").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = comps.host, !host.isEmpty else { return nil }
        comps.scheme = scheme
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        if comps.port == nil && scheme == "http" {
            comps.port = DeviceHubDefaults.port
        }
        return comps.url
    }
}

enum DeviceHubDefaults {
    /// 设备服务默认端口（桥接 config.json 的 device.port）：配对、轮询、指令结果。
    static let port = 3101
    /// 实时感官通道默认端口（config.json 的 sense.port）：WS 音频 + 端上文字事件。
    static let sensePort = 3102
}

/// 一条通道的观测状态，随心跳一起报给桥接，界面也用它显示"现在走哪条"。
struct BridgeChannelState: Codable, Equatable {
    var tag: String
    var url: String
    var active: Bool = false
    var latencyMs: Int?
    var lastOkAt: Int?
    var lastFailAt: Int?

    /// 心跳里的 JSON 形状：{tag,url,active,latencyMs,lastOkAt,lastFailAt}。
    var payload: [String: Any] {
        var dict: [String: Any] = ["tag": tag, "url": url, "active": active]
        if let value = latencyMs { dict["latencyMs"] = value }
        if let value = lastOkAt { dict["lastOkAt"] = value }
        if let value = lastFailAt { dict["lastFailAt"] = value }
        return dict
    }
}

struct EndpointProbe: Sendable {
    let tag: String
    let ok: Bool
    let latencyMs: Int
    let error: String
}

/// 多端点择优 + 故障切换。
///
/// 规则（和 bridge 侧 scripts/test-device-bridge.mjs 的镜像用例一一对应）：
/// 1. 启动时按配置顺序依次探测 `GET /api/device/ping`，每个 3 秒超时；
///    在可达端点里选延迟最低的，延迟并列时取配置顺序靠前的。
/// 2. 运行中连续 3 次请求失败才切换，避免一次网络抖动就把通道换掉。
/// 3. 切换时只探测"除当前以外"的端点；都不可达则 30 秒后重新全量探测。
///
/// 探测是串行的：3 条通道最坏 9 秒完成首次择优。这个代价只出现在启动和
/// 全部不可达之后，换来的是不需要把 URLSession 跨并发域传递（避免 Swift 6 的 Sendable 噪音）。
final class EndpointRouter {
    static let probeTimeout: TimeInterval = 3
    static let failThreshold = 3
    static let allFailedCooldown: TimeInterval = 30

    private(set) var endpoints: [BridgeEndpoint]
    private(set) var channels: [String: BridgeChannelState]
    private(set) var active: BridgeEndpoint?
    private(set) var activeURL: URL?
    private(set) var consecutiveFailures = 0
    private(set) var lastProbeAt: Date?

    private var cooldownUntil: Date?
    private let session: URLSession

    init(endpoints: [BridgeEndpoint] = []) {
        self.endpoints = endpoints
        self.channels = [:]
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = EndpointRouter.probeTimeout + 1
        cfg.timeoutIntervalForResource = EndpointRouter.probeTimeout + 3
        cfg.httpShouldUsePipelining = false
        self.session = URLSession(configuration: cfg)
        syncChannels()
    }

    var channelList: [BridgeChannelState] { endpoints.compactMap { channels[$0.tag] } }

    var activeTag: String { active?.tag ?? "未连接" }

    var inCooldown: Bool {
        if let until = cooldownUntil { return Date() < until }
        return false
    }

    func updateEndpoints(_ newEndpoints: [BridgeEndpoint]) {
        endpoints = newEndpoints
        active = nil
        activeURL = nil
        consecutiveFailures = 0
        cooldownUntil = nil
        syncChannels()
    }

    private func syncChannels() {
        var next: [String: BridgeChannelState] = [:]
        for endpoint in endpoints {
            if var existing = channels[endpoint.tag] {
                existing.url = endpoint.url
                existing.active = (active?.tag == endpoint.tag)
                next[endpoint.tag] = existing
            } else {
                next[endpoint.tag] = BridgeChannelState(tag: endpoint.tag, url: endpoint.url)
            }
        }
        channels = next
    }

    private func activate(_ endpoint: BridgeEndpoint) {
        active = endpoint
        activeURL = endpoint.baseURL()
        for (tag, var state) in channels {
            state.active = (tag == endpoint.tag)
            channels[tag] = state
        }
    }

    private func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private func record(_ probe: EndpointProbe, url: String) {
        var state = channels[probe.tag] ?? BridgeChannelState(tag: probe.tag, url: url)
        state.url = url
        if probe.ok {
            state.lastOkAt = nowMs()
            state.latencyMs = probe.latencyMs
        } else {
            state.lastFailAt = nowMs()
            state.latencyMs = nil
        }
        channels[probe.tag] = state
    }

    private func bestOf(_ probes: [EndpointProbe]) -> EndpointProbe? {
        var best: EndpointProbe?
        for probe in probes where probe.ok {
            if let current = best {
                if probe.latencyMs < current.latencyMs { best = probe }
            } else {
                best = probe
            }
        }
        return best
    }

    /// 单端点探活。任何异常都只是"这条不通"，不往上抛。
    func probe(_ endpoint: BridgeEndpoint, token: String) async -> EndpointProbe {
        guard let base = endpoint.baseURL(),
              let url = URL(string: base.absoluteString + "/api/device/ping") else {
            return EndpointProbe(tag: endpoint.tag, ok: false, latencyMs: 0, error: "地址不合法：\(endpoint.url)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = EndpointRouter.probeTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(token, forHTTPHeaderField: "x-device-token")
        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if code == 200 && (obj?["ok"] as? Bool) == true {
                return EndpointProbe(tag: endpoint.tag, ok: true, latencyMs: ms, error: "")
            }
            return EndpointProbe(tag: endpoint.tag, ok: false, latencyMs: ms, error: "HTTP \(code)")
        } catch {
            return EndpointProbe(tag: endpoint.tag,
                                 ok: false,
                                 latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                                 error: error.localizedDescription)
        }
    }

    /// 启动 / 冷却结束后的全量择优。
    @discardableResult
    func refreshActive(token: String) async -> EndpointProbe? {
        lastProbeAt = Date()
        var probes: [EndpointProbe] = []
        for endpoint in endpoints {
            let probe = await self.probe(endpoint, token: token)
            record(probe, url: endpoint.url)
            probes.append(probe)
        }
        if let best = bestOf(probes), let endpoint = endpoints.first(where: { $0.tag == best.tag }) {
            activate(endpoint)
            consecutiveFailures = 0
            cooldownUntil = nil
            return best
        }
        active = nil
        activeURL = nil
        cooldownUntil = Date().addingTimeInterval(EndpointRouter.allFailedCooldown)
        return nil
    }

    func noteSuccess() {
        consecutiveFailures = 0
        cooldownUntil = nil
        if let tag = active?.tag, var state = channels[tag] {
            state.lastOkAt = nowMs()
            channels[tag] = state
        }
    }

    /// 记一次失败；返回是否到了"该换通道"的阈值（连续 3 次）。
    @discardableResult
    func noteFailure() -> Bool {
        consecutiveFailures += 1
        if let tag = active?.tag, var state = channels[tag] {
            state.lastFailAt = nowMs()
            channels[tag] = state
        }
        return consecutiveFailures >= EndpointRouter.failThreshold
    }

    /// 换通道：只探其余端点，选延迟最低的可达项；都不可达则进入 30 秒冷却。
    @discardableResult
    func failover(token: String) async -> EndpointProbe? {
        let currentTag = active?.tag
        let candidates = endpoints.filter { $0.tag != currentTag }
        consecutiveFailures = 0
        guard !candidates.isEmpty else {
            active = nil
            activeURL = nil
            cooldownUntil = Date().addingTimeInterval(EndpointRouter.allFailedCooldown)
            return nil
        }
        var probes: [EndpointProbe] = []
        for endpoint in candidates {
            let probe = await self.probe(endpoint, token: token)
            record(probe, url: endpoint.url)
            probes.append(probe)
        }
        if let best = bestOf(probes), let endpoint = endpoints.first(where: { $0.tag == best.tag }) {
            activate(endpoint)
            cooldownUntil = nil
            return best
        }
        active = nil
        activeURL = nil
        cooldownUntil = Date().addingTimeInterval(EndpointRouter.allFailedCooldown)
        return nil
    }
}
