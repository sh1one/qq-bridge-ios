import SwiftUI
import UIKit

@main
struct XiaoBeiMingApp: App {
    @StateObject private var controller = DeviceController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .onAppear { controller.bootstrap() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DeviceController
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: controller.awake
                    ? [Color(red: 0.05, green: 0.09, blue: 0.16), Color(red: 0.02, green: 0.04, blue: 0.08)]
                    : [Color(red: 0.09, green: 0.09, blue: 0.10), Color(red: 0.04, green: 0.04, blue: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                header
                statusGrid
                Spacer(minLength: 0)
                bigButton
                footNote
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 26)

            if let notice = controller.notice {
                NoticeBanner(text: notice)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(showSettings: $showSettings)
                .environmentObject(controller)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("小北冥")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(controller.awake ? "感官在线 · 正在听桥接" : "待机中")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var statusGrid: some View {
        VStack(spacing: 0) {
            StatusRow(label: "连接", value: controller.connState, tint: controller.connected ? .green : .orange)
            Divider().opacity(0.25)
            StatusRow(label: "电量", value: controller.batteryText, tint: .primary)
            Divider().opacity(0.25)
            StatusRow(label: "模式", value: controller.awake ? "awake" : "standby", tint: controller.awake ? .cyan : .secondary)
            Divider().opacity(0.25)
            StatusRow(label: "通道", value: controller.activeChannel, tint: controller.activeChannel == "未连接" ? .secondary : .green)
            Divider().opacity(0.25)
            StatusRow(label: "端点", value: controller.channelDetail, tint: .secondary)
            Divider().opacity(0.25)
            StatusRow(label: "她正在", value: controller.activity, tint: .purple)
            if controller.listenRunning {
                Divider().opacity(0.25)
                StatusRow(label: "常驻监听", value: listenSummary, tint: .green)
            }
            if !controller.lastError.isEmpty {
                Divider().opacity(0.25)
                StatusRow(label: "最近错误", value: controller.lastError, tint: .red)
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 首页只显示「几段 · 最近一句开头」，整段文字留给设置页。
    private var listenSummary: String {
        let text = controller.listenLastText.isEmpty ? "在听" : shortText(controller.listenLastText, limit: 40)
        return "\(controller.listenSegments) 段 · \(text)"
    }

    private var bigButton: some View {
        Button {
            controller.toggleAwake()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: controller.awake ? "eye.slash" : "eye")
                    .font(.system(size: 34, weight: .light))
                Text(controller.awake ? "待机" : "唤醒")
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 148)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(controller.awake
                          ? Color.white.opacity(0.06)
                          : Color(red: 0.16, green: 0.42, blue: 0.72).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footNote: some View {
        Text(controller.tokenConfigured
             ? "摄像头/麦克风只在收到桥接指令时启动，每次执行前会在屏幕顶部显示提示。当前走「\(controller.activeChannel)」通道。"
             : "还没有填接入通道与令牌：点右上角设置后才开始连接。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(tint)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// 指令执行前的可见提示。她能看到"手机正在被使用"，而不是无声无息被拍。
struct NoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 1.0, green: 0.82, blue: 0.28))
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: DeviceController
    @Binding var showSettings: Bool
    @State private var lan: String = ""
    @State private var tailscale: String = ""
    @State private var tunnel: String = ""
    @State private var token: String = ""
    @State private var useOnDeviceASR: Bool = true
    @State private var asrModel: OnDeviceModel = .small
    @State private var vadSilenceMs: Int = 800
    @State private var continuousListen: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("lan · 家里 WiFi") {
                    TextField("http://192.168.1.23:3101", text: $lan)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("最快，但出门就用不了。不写端口时默认 3101。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("tailscale · 远程首选") {
                    TextField("http://100.x.y.z:3101", text: $tailscale)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("电脑和手机都装 Tailscale、登同一账号，手机填电脑的 100.x 地址。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("tunnel · 兜底") {
                    TextField("https://xxx.example.com", text: $tunnel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Cloudflare Tunnel 之类的域名；https 不补端口。三条通道按顺序探测，选延迟最低的那条。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("设备引导令牌") {
                    TextField("state/device/token 里的那串字符", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Text("令牌在电脑的 C:\\Users\\zwc\\qq-bridge\\state\\device\\token（或 config.json 的 device.token）。第一次连上会自动配对并换成设备令牌。没填令牌时 App 不发起任何连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("端上识别（WhisperKit）", isOn: $useOnDeviceASR)
                    Picker("模型", selection: $asrModel) {
                        ForEach(OnDeviceModel.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    Stepper(value: $vadSilenceMs, in: 800...1000, step: 50) {
                        Text("静音 \(vadSilenceMs) ms 后收尾")
                    }
                    HStack(spacing: 10) {
                        Text(controller.asrState.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if controller.asrState.isPreparing {
                            ProgressView(value: min(max(controller.asrState.progress, 0), 1))
                                .frame(width: 90)
                        }
                    }
                    Button("准备模型（下载 + 预编译）") {
                        Task { await controller.prepareASR() }
                    }
                    .disabled(controller.asrState.isPreparing)
                    if !controller.asrState.lastError.isEmpty {
                        Text(controller.asrState.lastError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("端上识别（A15）")
                } footer: {
                    Text("开启后录音在手机本地转成文字，只把文字发给桥接；识别失败会自动回退到原来的音频上传。small 约 484 MB，首次要点「准备模型」下载并预编译（几十秒到几分钟），之后 2 秒语音的目标是 ≤1.2 秒。关掉此开关即完全恢复服务端转写。")
                        .font(.caption2)
                }
                Section {
                    Toggle("常驻监听（后台也听）", isOn: $continuousListen)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(controller.listenRunning ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text(controller.listenRunning ? "正在听（挂着 CallKit 通话）" : "未运行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("已采集 \(controller.listenSegments) 段")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("最近一段")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(listenLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    if !controller.listenLastError.isEmpty {
                        Text(controller.listenLastError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("常驻监听")
                } footer: {
                    Text(continuousListen
                         ? "会挂一通「小北冥」的假通话（CallKit）来保住麦克风：锁屏、后台都能继续听。声音只在手机本地转成文字，只把文字发给电脑；转写失败的段直接丢掉。"
                         : "需要 App 在前台，锁屏会停。打开后会挂一通假通话来保住麦克风，锁屏也能继续听。")
                        .font(.caption2)
                }
                Section {
                    Button("保存并重连") {
                        controller.updateAppSettings(
                            useOnDeviceASR: useOnDeviceASR,
                            model: asrModel,
                            vadSilenceMs: vadSilenceMs,
                            vadThreshold: controller.settings.vadThreshold,
                            continuousListen: continuousListen
                        )
                        controller.saveSettings(lan: lan, tailscale: tailscale, tunnel: tunnel, token: token)
                        showSettings = false
                    }
                    .disabled(!hasEndpoint || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("至少填一条通道。现在：\(controller.channelDetail)")
                        .font(.caption2)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSettings = false }
                }
            }
            .onAppear {
                lan = controller.lanURL
                tailscale = controller.tailscaleURL
                tunnel = controller.tunnelURL
                token = controller.token
                useOnDeviceASR = controller.settings.useOnDeviceASR
                asrModel = controller.settings.model
                vadSilenceMs = controller.settings.vadSilenceMs
                continuousListen = controller.settings.continuousListen
            }
        }
    }

    /// 最近一段只显示开头 40 字：整句话会把设置页那一行撑开。
    private var listenLine: String {
        let text = controller.listenLastText
        if text.isEmpty { return controller.listenRunning ? "还没听到说话" : "—" }
        return shortText(text, limit: 40)
    }

    private var hasEndpoint: Bool {
        [lan, tailscale, tunnel].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// 把一段文字压成一行（保留前 `limit` 个字符）。状态行、最近转写都用它。
private func shortText(_ text: String, limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
}
