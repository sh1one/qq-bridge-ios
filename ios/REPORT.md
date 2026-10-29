# 小北冥感官器官 · 交付报告

> 生成时间：2026-10-29（Europe/Rome）
> 工作目录：`C:\Users\zwc\qq-bridge`
> 约束遵守情况：未重启 DSH；桥接重启过两次（`启动桥接.bat` 的 :loop 自动拉起）；未新增 npm 依赖；iOS 侧零第三方库；所有新文件 UTF-8 无 BOM、纯 LF（已用 node 逐字节核对 `bom=false cr=false`）。

## 1. 文件清单

### 1.1 本轮新建/改动的交付文件

| 文件 | 字节 | 行数 | 说明 |
| --- | --- | --- | --- |
| `src/sense-hub.js` | 24991 | 707 | **新增**：实时感官通道（手写 WebSocket 服务端、PCM 切片落盘、VAD 统计、状态流） |
| `src/device-hub.js` | 41146 | 995 | 设备指令枢纽（多设备、令牌分离、限流、outbox） |
| `src/device-tools.js` | 16784 | 323 | 她的 5 个手机工具（MCP 薄封装） |
| `src/bridge.js` | 758739 | 13602 | 接线：设备服务 + 感官服务 + 控制台路由（本会话新增约 120 行） |
| `scripts/test-device-bridge.mjs` | 28670 | 582 | 设备链路自测（in-process 84 项 + `--live` 13 项） |
| `scripts/test-sense-stream.mjs` | 12986 | 321 | **新增**：实时通道自测（in-process 35 项 + `--live` 26 项） |
| `scripts/check-ios-sources.mjs` | 9791 | 271 | iOS 源码静态检查（Windows 上唯一能做的一致性检查） |
| `ios/Sources/App.swift` | 10183 | 256 | 首页 + 设置页 |
| `ios/Sources/BridgeClient.swift` | 12293 | 298 | HTTP 客户端（poll/result/heartbeat/ping/pair） |
| `ios/Sources/EndpointRouter.swift` | 10366 | 275 | 三通道择优 + 失败切换 |
| `ios/Sources/DeviceController.swift` | 27178 | 663 | 状态机：连接/保活/指令分发/审计 |
| `ios/Sources/SenseStream.swift` | 17264 | 466 | **新增**：常驻收音 WebSocket 上行 + VAD + barge-in + 功耗策略 |
| `ios/Sources/KeepAlive.swift` | 6476 | 172 | 静音音频保活 |
| `ios/Sources/CameraService.swift` | 8321 | 233 | 前/后摄拍照、JPEG、手电筒 |
| `ios/Sources/MicService.swift` | 5528 | 144 | 定长录音 16k wav + RMS 静音检测 |
| `ios/Sources/SpeechService.swift` | 4361 | 123 | audioUrl 播放 + zh-CN TTS 兜底 |
| `ios/Sources/HapticsService.swift` | 5479 | 138 | 四种情绪脉冲 |
| `ios/Sources/OpenAppService.swift` | 3709 | 81 | URL Scheme 打开 App |
| `ios/project.yml` | 1321 | 51 | xcodegen 工程描述 |
| `ios/Info.plist` | 2706 | 80 | 权限与后台模式 |
| `ios/Resources/silence.wav` | 88244 | — | 1 秒静音 PCM（保活用） |
| `ios/README.md` | 22380 | 333 | Windows 侧完整步骤 + 远程接入 + 实时通道 |
| `.github/workflows/ios-build.yml` | 3102 | 93 | macOS runner 出未签名 IPA |

### 1.2 运行时产物（真实存在，非示例）

- `state/device/results/` 3 个结果 JSON、`state/device/media/` 3 个媒体文件（假 JPEG，自测产生）
- `state/sense/` 4 个 wav（16 kHz 单声道，2.4 s/片）+ `index.jsonl`
- `state/device/devices.json`（只存 sha256，无明文令牌）

## 2. 桥接接口契约

### 2.1 设备指令接口（端口 3101，`config.device.port`）

所有请求都要设备令牌：`?token=` 或 `x-device-token` 头，`crypto.timingSafeEqual` 比较。主控 token 打进来一律 401。

```http
GET /api/device/ping
→ {"ok":true,"pong":true,"service":"qq-bridge-device","apiVersion":2,"serverTime":1793285087067,"port":3101,"online":true,"deviceId":"bootstrap"}
```

```http
POST /api/device/pair        # 必须用引导令牌（state/device/token）
{"deviceId":"curl-demo-01","deviceName":"curl-demo"}
→ {"ok":true,"deviceId":"curl-demo-01","deviceToken":"6nlgL1vjjlBjXSXB_zdzjjdkZiQDd6F5","deviceName":"curl-demo","serverTime":1793285092191,"apiVersion":2}
```

```http
GET /api/device/poll?wait=25000
→ 有指令：{"ok":true,"commands":[{"id":"cmvtn...","cmd":"look","args":{"camera":"back"}}],"serverTime":...,"longPollMs":0}
→ 空闲：  {"ok":true,"commands":[],"serverTime":...,"longPollMs":24987,"idle":true}
```

```http
POST /api/device/result
{"id":"cmvtnmw475e079b54","ok":true,"data":{"width":1280,"height":960},
 "media":{"ext":"jpg","base64":"/9j/4AAQSkZJRg..."}}
→ {"ok":true,"id":"cmvtnmw475e079b54","mediaPath":"C:\\Users\\zwc\\qq-bridge\\state\\device\\media\\cmvtnmw475e079b54.jpg","savedAt":"2026-10-29T..."}
```

```http
POST /api/device/heartbeat
{"battery":73,"charging":true,"mode":"awake","deviceName":"iPhone 13 Pro Max",
 "appVersion":"1.0.0(1)","channels":[{"tag":"lan","url":"http://192.168.1.70:3101","active":true,"latencyMs":12,"lastOkAt":1793285000000}]}
→ {"ok":true,"serverTime":1793285092253,"nextHeartbeatMs":20000,"queueDepth":0,"apiVersion":2,"deviceId":"curl-demo-01","revoked":false}
```

```http
GET /api/device/status
→ {"ok":true,"apiVersion":2,"online":true,"lastSeenIso":"2026-10-29T14:44:52.253Z","onlineTtlMs":75000,
   "battery":73,"charging":true,"mode":"awake","deviceName":"iPhone 13 Pro Max",
   "queueDepth":0,"pending":[],"waitingPolls":0,"requestLimitPerMin":120,
   "devices":[{"id":"curl-demo-01","name":"curl-demo","online":true,"revoked":false,
               "channels":[{"tag":"lan","active":true,"latencyMs":12},...]}],
   "stats":{"commandsSent":1,"resultsOk":1,"resultsFailed":0,"mediaSaved":1,"rateLimited":0},
   "lanAddresses":["http://26.162.69.9:3101","http://192.168.1.70:3101"]}
```

`GET /api/device/audio/<name>?token=…` 是给 `AVAudioPlayer` 用的静态音频出口（outbox，最多保留 32 个）。

失败码：`UNAUTHORIZED`(401) / `CONSOLE_TOKEN_FORBIDDEN`(401) / `DEVICE_REVOKED`(403) / `NEED_BOOTSTRAP_TOKEN`(403) / `RATE_LIMITED`(429 + `retry-after`) / `BAD_CMD` / `BAD_ARGS` / `OFFLINE` / `QUEUE_FULL` / `TIMEOUT`。

### 2.2 实时感官通道（端口 3102，`config.sense.port`）

```http
GET  /api/sense/status     # 会话列表、帧数、已收秒数、功耗档、统计；不回显 token
POST /api/sense/say        {"text":"我在听"} 或 {"audioUrl":"http://..."}
POST /api/sense/state      {"state":"thinking","detail":"在查天气"}
GET  /api/sense/wav?name=sxxx-0000.wav
```

```text
WS /api/sense/audio?token=<设备令牌>
← 文本帧 {"type":"hello","sessionId":"s6910b7d398b8","sampleRate":16000,"encoding":"pcm_s16le","flushSeconds":10}
→ 文本帧 {"type":"hello","deviceName":"iPhone 13 Pro Max","powerMode":"balanced"}  → hello_ack
→ 二进制帧 16 kHz 单声道 PCM16LE（40 ms = 1280 字节）
→ 文本帧 {"type":"speech_start"} / {"type":"speech_end"} / {"type":"heartbeat","powerMode":"low"}
← 文本帧 {"type":"utterance","file":"s6910b7d398b8-0000.wav","durationSec":2.4}
← 文本帧 {"type":"say","text":"我在听"} / {"type":"state","state":"thinking"}
```

每 10 秒或收到 `speech_end` 落一个 wav 到 `state/sense/`，同时写 `index.jsonl`（时长、RMS、是否有人声）。

### 2.3 控制台内部接口（127.0.0.1:3100，主控 token）

`POST /api/device/command`（body `{cmd,args,timeoutMs,source}`，`say` 带 `audioPath` 会转成 `audioUrl`）、`GET /api/device/devices`、`POST /api/device/devices/revoke`、`GET /api/sense/status`、`POST /api/sense/say`、`POST /api/sense/state`。

### 2.4 她可用的工具（MCP `mcp__snowluma__*`）

`phone_look`（返回图片本体给视觉模型）、`phone_listen`、`phone_say`、`phone_haptic`、`phone_open_app`。每个都是参数校验 + 超时（look 30s、listen `secs*1000+15000`、say 30s、haptic 15s、openApp 20s），不做业务逻辑。

## 3. 端到端自测输出（真实输出）

```text
$ node scripts/test-device-bridge.mjs
===== 结果：84 通过 / 0 失败 =====

$ node scripts/test-device-bridge.mjs --live
ok   live poll 不带 token → 401 — 实际 401 期望 401
ok   live 手机 poll 取到 look — cmvtnmw475e079b54
ok   live 控制台 /api/device/command 返回 ok:true — {"ok":true,"id":"cmvtnmw475e079b54","cmd":"look","data":{"width":1280,"height":960,"camera":"back"},"error":"","mediaPath":"C:\\Users\\zwc\\qq-bridge\\state\\device\\media\\cmvtnmw475e079b54.jpg","mediaBytes":4096,"elapsedMs":136}
ok   live 落盘字节数一致 — 实际 4096 期望 4096
ok   live 统计里有落盘计数 — mediaSaved=1
===== 结果：13 通过 / 0 失败 =====

$ node scripts/test-sense-stream.mjs
ok   speech_end 后收到 utterance — 实际 utterance 期望 utterance
ok   wav 采样率 16000 — 实际 16000 期望 16000
ok   wav 长度自洽 — bytes=76844 data=76800
ok   status 不泄露 token — 实际 false 期望 false
ok   say 内容是下发的那句 — 实际 我在听 期望 我在听
ok   手机收到状态流 — 实际 thinking 期望 thinking
===== 结果：35 通过 / 0 失败 =====

$ node scripts/test-sense-stream.mjs --live
ok   错误 token 的 WS 握手被拒
ok   hello 采样率 — 实际 16000 期望 16000
ok   utterance 时长约 2.4s — 2.4s
ok   pushSay 返回 ok — 实际 true 期望 true
===== 结果：26 通过 / 0 失败 =====

$ node scripts/check-ios-sources.mjs
== 结果：88 通过 / 0 失败（11 个 Swift 文件）==
```

curl 闭环（真实输出，已去掉多行响应的换行）：

```text
== ping（引导令牌）==
{"ok":true,"pong":true,"service":"qq-bridge-device","apiVersion":2,"serverTime":1793285087067,"port":3101,"online":true,"deviceId":"bootstrap"}

== 主控令牌打设备接口（必须拒绝）==
{"ok":false,"code":"CONSOLE_TOKEN_FORBIDDEN","error":"这是主控 token：设备接口只认设备 token（config.device.token 或手机配对后拿到的 deviceToken）"}
HTTP=401

== pair ==
{"ok":true,"deviceId":"curl-demo-01","deviceToken":"6nlgL1vjjlBjXSXB_zdzjjdkZiQDd6F5","deviceName":"curl-demo","serverTime":1793285092191,"apiVersion":2}

== heartbeat ==
{"ok":true,"serverTime":1793285092253,"nextHeartbeatMs":20000,"queueDepth":0,"apiVersion":2,"deviceId":"curl-demo-01","revoked":false}

== 实时通道没有连手机时说一句（不是假装成功）==
{"ok":false,"code":"NO_SESSION","error":"没有连着的手机"}   ← 修复后行为（旧版会误报 queued）
```

时延口径：`deviceCommand` 的 `elapsedMs` 是"入队→收到结果"（live 自测 136 ms，纯本机回环）；超时用 `timeoutMs=400` 实测 403 ms 返回 `TIMEOUT` 且队列已摘除（in-process 用例）。

## 4. iOS 工程结构与保活关键代码

```text
ios/
├── project.yml                 # xcodegen 工程描述（XiaoBeiMing / com.xiaobeiming.senses）
├── Info.plist                  # UIBackgroundModes=[audio]、相机/麦克风/本地网络、ATS 允许局域网明文
├── Resources/silence.wav       # 1 秒静音，保活循环播放
└── Sources/
    ├── App.swift               # 首页（连接/电量/模式/通道/端点/她正在/最近错误）+ 设置页
    ├── BridgeClient.swift      # poll / result / heartbeat / ping / pair
    ├── EndpointRouter.swift    # lan → tailscale → tunnel 串行探测、延迟择优、连续 3 次失败切换
    ├── DeviceController.swift  # awake 状态机、指令分发（look/listen/say/haptic/openApp/torch/ping）、本地审计
    ├── KeepAlive.swift         # 静音循环 + 打断恢复 + 看门狗
    ├── SenseStream.swift       # 常驻收音：AVAudioEngine → 16k PCM → WS；VAD；barge-in；功耗档
    ├── CameraService.swift     # 前/后摄、JPEG 长边 1280、quality 0.7、手电筒
    ├── MicService.swift        # 定长 wav、RMS 静音检测
    ├── SpeechService.swift     # audioUrl 播放（克隆音色）+ zh-CN TTS 兜底
    ├── HapticsService.swift    # heartbeat/shiver/pulse/buzz + 降级
    └── OpenAppService.swift    # URL Scheme 打开微信/支付宝/QQ/设置…
```

保活实现（`KeepAlive.swift` 核心 22 行，真实摘录）：

```swift
private func configure() throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try audio.setActive(true, options: [])
}

func start() {
    guard player == nil else { return }
    do {
        try configure()
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { return }
        player = try AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1      // 无限循环，1 秒静音
        player?.volume = 0              // 听不见，但音频会话真的在输出
        player?.play()
        startWatchdog()                 // 5 秒检查一次，被系统停了就重放
    } catch { lastError = "保活音频启动失败：\(error.localizedDescription)" }
}
```

三件系统事实（代码按此实现，README 里也写死）：

1. 后台存活必须有真实音频输出 → `.playback` + `UIBackgroundModes: audio` + 静音循环；
2. 后台**不能**上摄像头（系统限制，不是权限）→ `look` 只能在前台/被唤起时执行；
3. 实时通道要收音 → 音频会话切成 `.playAndRecord`，因此 `SenseStream` 启动前让 `KeepAlive` 让位（`suspendForRecording`），停止后恢复。

## 5. GitHub Actions 构建

触发方式（三选一）：

1. 仓库 → Actions → **Build unsigned IPA** → Run workflow（`workflow_dispatch`）；
2. `git tag ios-v1.0.0 && git push origin ios-v1.0.0`（`push.tags: ios-v*`）；
3. `gh workflow run ios-build.yml`。

runner：`macos-14`（Xcode 15.x）。步骤：`brew install xcodegen` → `xcodegen generate --spec project.yml` → `xcodebuild -project XiaoBeiMing.xcodeproj -scheme XiaoBeiMing -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build` → `mkdir Payload && cp -R ... XiaoBeiMing.app Payload/ && zip -qry XiaoBeiMing.ipa Payload` → `shasum -a 256`。

产物：artifact 名 **`XiaoBeiMing-unsigned-ipa`**，内含 `XiaoBeiMing.ipa` + `SHA256SUMS.txt`；构建失败时另传 `build-log`（保留 14 天）。

## 6. Windows 侧安装步骤

1. 电脑装 **AltServer**（altstore.io）+ 官网版 iTunes 与 iCloud（**不要** Microsoft Store 版）。
2. `state/device/token` 里的 32 位字符串 = 手机要填的**设备引导令牌**（不是 `state/console-token`）。
3. 确认桥接在跑，且 `3101`/`3102` 都监听：`Get-NetTCPConnection -State Listen | ? LocalPort -in 3101,3102`。
4. Windows 防火墙放行 TCP 3101 与 3102（专用网络）。
5. iPhone 与电脑连同一 WiFi（无 AP 隔离）；首次连接允许「本地网络」权限。
6. 从 Actions 下载 `XiaoBeiMing-unsigned-ipa`，解开得到 `XiaoBeiMing.ipa`。
7. iPhone 用数据线连电脑 → AltServer 托盘 → Install AltStore → 输入 Apple ID（免费账号即可）。
8. iPhone 设置 → 通用 → VPN与设备管理 → 信任开发者证书；设置 → 隐私与安全性 → **开发者模式** 打开并重启。
9. AltStore → My Apps → `+` → 选 `XiaoBeiMing.ipa` 安装。
10. 打开 App → 设置页填三条通道（局域网 `http://192.168.1.x:3101`，可留空）+ 引导令牌 → 保存并重连。
11. 点「唤醒」：状态行出现通道名（lan/tailscale/tunnel）+ 电量；顶部出现实时通道状态。
12. **7 天续签**：AltServer 托盘 → 勾选 `Refresh Apps Over Wi-Fi`，iPhone 与电脑同一 WiFi 且 AltServer 常开 → AltStore 会在到期前自动后台刷新；电脑必须开机。备选：SideStore（同样 7 天，但可自签 Anisette）、或 99 美元/年开发者账号（1 年，无需续签）。
13. 出门在外：电脑与手机都装 Tailscale、同账号登录，手机端把 tailscale 那条填成 `http://100.x.y.z:3101`；iOS Tailscale 里开「按需连接」。
14. 排错：401 `CONSOLE_TOKEN_FORBIDDEN` → 填错成主控 token；`DEVICE_REVOKED` → 该设备被吊销（不可逆，需手改 devices.json）；所有通道都连不上 → 先在电脑 `curl http://127.0.0.1:3101/api/device/ping` 确认桥接活着。

## 7. 未验证项与已知风险

**未验证（没有真机，也没有 Mac）**

1. **App 从未编译过**：Windows 上没有 Swift/Xcode 工具链，GitHub Actions 也还没真正跑过一次（本机没有推送权限）。所有 Swift 文件只过了自写的静态检查（88 项：编码/缩进/括号/import 白名单/Info.plist/project.yml/workflow/静音 wav 头），**没有一次 `swiftc` 或 `xcodebuild`**。首次 Actions 构建大概率会有编译错误要修。
2. **实时通道的三条验收指标全部未测**：后台锁屏连续 30 分钟不断、20 次端到端延迟中位数、连续 1 小时耗电曲线。桥接侧与 Node 模拟客户端已跑通（35 + 26 项），真机数据只能装上去再测。
3. **保活在实际系统压力下的表现未测**：静音循环能不能扛住低电量模式/内存压力，只有真机能回答。
4. **摄像头/麦克风/触感/URL Scheme 的实际行为未测**（包括"后台不能上摄像头"这条限制的实际表现）。
5. **7 天续签流程未在真机走过**。

**已知风险**

1. **本轮曾把桥接改崩过**：`currentConsoleToken()` 误用了 `main()` 作用域里的 `cfg`，抛 `ReferenceError: cfg is not defined`，桥接启动即退（QQ 桥接短时离线）。`node --check` 查不出这类作用域错误，是 `启动桥接.bat` 的 :loop 反复重启 + `state/bridge.log` 的堆栈定位的；已改为函数内 `loadConfig()`，重启后 `DSH 已就绪（模式: reserved2）`。教训：模块级函数不许摸 `main()` 里的闭包变量。
2. **PowerShell 5.1 会剥掉 `curl.exe -d '{...}'` 的双引号** → `BAD_JSON`。所有 JSON body 必须先 `[System.IO.File]::WriteAllText` 写到文件再 `-d "@file"`。
3. **Opus 没做**：iOS 系统框架没有 Opus 编码器，项目又禁止第三方库，P1 用 PCM16 16k（≈256 kbps）。省流量要等 AAC 方案或解禁依赖。
4. **STT/TTS 闭环没接**：wav 已按片落盘、`say` 能推到手机，但桥接还没调用 whisper 与 7880 端口的 IndexTTS-2.5。所以现在是"听→落盘"和"桥接→说"两段，不是完整闭环。
5. **App 没有图标**（没做 Assets.xcassets），装上去是空白图标。
6. **吊销不可逆**：`POST /api/device/devices/revoke` 之后只能手改 `devices.json` 才能复活。
7. **设备服务默认监听 0.0.0.0**（3101/3102）：局域网内可达，安全全靠 device token 与限流；不要把它暴露到公网而不加隧道/鉴权。
8. **`mcp-snowluma-safe.js` 的 `phone_*` 工具需要重启 DSH 才生效**，本轮按约束没有重启 DSH —— 也就是说工具已经注册进代码，但当前 DSH 进程里还看不到它们。