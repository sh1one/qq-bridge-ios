# 小北冥 · iPhone 感官 App（侧载）

把一台 iPhone 13 Pro Max 变成她的眼睛、耳朵、嘴和情绪：

| 器官 | iOS 实现 | 桥接指令 |
| --- | --- | --- |
| 眼睛 | `AVCaptureSession` 前/后摄，JPEG 长边 1280、质量 0.7 | `look` |
| 耳朵 | `AVAudioRecorder` 固定时长，16kHz 单声道 wav + RMS 静音检测 | `listen` |
| 嘴 | `AVAudioPlayer` 播克隆音色 wav；纯文字时 `AVSpeechSynthesizer`(zh-CN) 兜底 | `say` |
| 情绪 | `CoreHaptics` 四种预设脉冲，无硬件时回落 `UIImpactFeedbackGenerator` | `haptic` |
| 手 | `UIApplication.open(url)` 跳 App（微信/支付宝/QQ/相机…） | `openApp` |

后台常驻靠 `UIBackgroundModes = audio` + 循环播放 1 秒静音 wav（`KeepAlive.swift`）。
**这只在系统压力小时有效，不是"永不杀"**。App Store 不允许这种用法，所以只走侧载。

---

## 0. 目录结构

```
ios/
├── project.yml                 # xcodegen 工程描述（不提交 pbxproj）
├── Info.plist                  # 权限文案 / UIBackgroundModes=audio / ATS
├── Resources/silence.wav       # 1 秒静音，保活循环播放
└── Sources/
    ├── App.swift               # 最小界面：连接状态、电量、通道、唤醒/待机
    ├── BridgeClient.swift      # HTTP 长轮询 + 心跳 + 结果上报 + 设备配对
    ├── EndpointRouter.swift    # 多通道探测/择优/故障切换（lan→tailscale→tunnel）
    ├── DeviceController.swift  # 指令分发、可见提示、本地 audit 日志
    ├── KeepAlive.swift         # 音频保活 + 中断恢复 + 看门狗
    ├── CameraService.swift     # 拍照 / 前后摄 / 手电筒
    ├── MicService.swift        # 录音 / 静音检测
    ├── SpeechService.swift     # 播克隆音色 / 系统 TTS 兜底
    ├── HapticsService.swift    # heartbeat / shiver / pulse / buzz
    └── OpenAppService.swift    # URL Scheme 跳 App
.github/workflows/ios-build.yml # macOS runner → 未签名 ipa
```

---

## 1. 构建：从 GitHub Actions 拿未签名 ipa（Windows 上不需要 Mac）

仓库根目录的 `.github/workflows/ios-build.yml` 会在 `macos-14` 上跑：

```
xcodebuild -project XiaoBeiMing.xcodeproj -scheme XiaoBeiMing \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

再把 `.app` 塞进 `Payload/`、`zip` 成 `XiaoBeiMing.ipa`，用 `actions/upload-artifact` 上传。

### 触发方式（三选一）

1. **网页点**：GitHub 仓库 → **Actions** → 左侧 **iOS Build (unsigned IPA)** → 右上 **Run workflow** → 分支选 `main` → **Run workflow**。
2. **命令行**（装过 `gh` 的话）：
   ```
   gh workflow run ios-build.yml
   gh run list --workflow=ios-build.yml
   ```
3. **推 tag**：
   ```
   git tag ios-v1
   git push origin ios-v1
   ```

### 下载

打开该次 run → 页面底部 **Artifacts** → 点击 **XiaoBeiMing-unsigned-ipa**（下载得到 `XiaoBeiMing-unsigned-ipa.zip`）→ 解压得到：

- `XiaoBeiMing.ipa`（就是它）
- `SHA256SUMS.txt`（校验用，可选）

> 产物名固定：`XiaoBeiMing.ipa`，bundle id 固定 `com.xiaobeiming.senses`。
> 失败时同一页面还能下载 `build-log` 看 xcodebuild 报错。

---

## 2. 电脑侧准备（Windows）

1. 确认桥接正在跑：浏览器打开 `http://127.0.0.1:3100/api/status` 有 JSON 就是活的。
2. 设备端口默认 **3101**，由桥接自己在 `0.0.0.0:3101` 起一个独立 HTTP 服务（控制台 3100 只绑 127.0.0.1，手机连不上）。
3. 拿**设备引导令牌**：
   ```
   type C:\Users\zwc\qq-bridge\state\device\token
   ```
   首次启动桥接时自动生成（与 console token 分开，两者**不通用**：拿主控 token 访问 `/api/device/*` 会直接 401 `CONSOLE_TOKEN_FORBIDDEN`）。**没配 token 时 App 拒绝连接**。也可以在 `config.json` 里写死 `device.token`（≥16 位、字母数字加 `-` `_`）。
   这个引导令牌只用来探活和「配对」；配对成功后手机会拿到一个独立的设备令牌（只在响应里返回一次），桥接只存它的 sha256，之后可以单独吊销某台设备。
4. 查电脑的局域网 IP（手机要填这个）：
   ```
   ipconfig | findstr IPv4
   ```
   记下形如 `192.168.1.23` 的那个（和手机同一个 WiFi）。
5. **Windows 防火墙**：第一次桥接监听 3101 时如果弹窗，勾选「专用网络」允许；没弹过就手动加一条入站规则：
   ```powershell
   New-NetFirewallRule -DisplayName "qq-bridge device 3101" -Direction Inbound -Protocol TCP -LocalPort 3101 -Action Allow -Profile Private
   ```
6. 手机和电脑连**同一个 WiFi**，且路由器没开「AP 隔离 / 客户端隔离」。

---

## 3. 在 Windows 上装 AltStore（免费 Apple ID 也行）

1. 下载 **AltServer**：<https://altstore.io/> → Windows 版 → 安装后右下角托盘出现菱形图标。
2. 电脑装 **iTunes**（Apple 官网版，不是 Microsoft Store 版）和 **iCloud**（同样官网版）。AltServer 依赖它们的 Apple 驱动；Store 版会被沙箱隔离，必须换官网版。
3. iPhone 用数据线连电脑 → 手机点「信任」→ 输入锁屏密码。
4. 托盘 AltServer 图标 → **Install AltStore** → 选你的 iPhone → 输入 **Apple ID 和密码**（会用于申请免费开发者证书；开了双重认证就用 **App 专用密码**）。
5. 手机上出现 AltStore 图标后，去 **设置 → 通用 → VPN与设备管理 → 开发者App** 里信任你的 Apple ID 证书。
6. **iPhone 设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机 → 重启后确认**（iOS 16+ 必须开，否则侧载 App 一启动就闪退）。
7. AltStore 里 **Settings → 登录 Apple ID**（如果第 4 步没自动登录），并打开 **Refresh Apps Over Wi-Fi**（续签要用）。

---

## 4. 用 AltStore 安装 ipa

1. 手机上的 **AltStore → My Apps → 左上角 +**。
2. 选刚解压出来的 `XiaoBeiMing.ipa`（在「文件」App 里能看到的目录，或用 iTunes 文件共享/隔空投送传进手机）。
3. 提示输入 Apple ID 密码 → 开始签名安装（约 10–60 秒）。
4. 装好后名字是 **小北冥**。首次启动会依次问相机、麦克风、本地网络权限，**全部允许**（本地网络那项必须允许，否则连不上桥接）。

> 免费 Apple ID 的限制：证书 7 天过期、最多 3 个自签 App、10 个 App ID / 7 天。
> 付费开发者账号（$99/年）是 1 年有效期，且不用每 7 天续。

---

## 5. App 内配置

1. 点右上角 **⚙︎**。
2. 有 **三条通道**，至少填一条（按 `lan → tailscale → tunnel` 的顺序探测，每个 3 秒超时，选延迟最低的那条）：
   - **lan**：家里 WiFi 直连，`http://192.168.1.23:3101`（不写端口默认补 3101）
   - **tailscale**：`http://100.x.y.z:3101`，出门首选，见第 5.5 节
   - **tunnel**：`https://xxx.example.com`，最后兜底（https 不补端口）
   - **设备引导令牌**：`state\device\token` 里的那串
3. 点 **保存并重连**。回主界面：**通道**那行显示 `lan` / `tailscale` / `tunnel`，**端点**那行显示每条通道的探测结果（例如 `lan:不通 · tailscale:38ms`），**连接**行显示 `已连接 · tailscale`。
4. 大按钮显示 **待机** 表示正在监听；显示 **唤醒** 表示当前是待机、没连桥接。点一下切换。

验证连通（电脑上跑，看到 `online: true` 就对了）：

```powershell
$t = Get-Content C:\Users\zwc\qq-bridge\state\device\token -Raw
curl.exe "http://127.0.0.1:3101/api/device/status?token=$t"
curl.exe -H "x-device-token: $t" "http://127.0.0.1:3101/api/device/ping"
```

### 5.5 远程接入（出门在外怎么连）

前提：桥接只在**这台电脑**上跑，手机要能找到它。三条通道建议一起配。

#### 首选：Tailscale（不开公网端口，WireGuard 加密）

1. 电脑和 iPhone 都装 Tailscale：<https://tailscale.com/download>（iPhone 走 App Store）。
2. 两边**登录同一个账号**。电脑上 `tailscale ip -4` 能看到 `100.x.y.z`。
3. iPhone 打开 Tailscale → 打开开关 → 设置里 **On-Demand（按需连接）→ 总是**。这样锁屏、切网络、重启后都会自己重连，不用每次手动开。
4. App 的 tailscale 通道填 `http://100.x.y.z:3101`（电脑的 100.x 地址 + 设备端口）。
5. 路由器上**不用开任何端口**，公网扫不到；打洞失败会自动走 Tailscale 中继（慢一点但能连）。代价是两边都要保持 Tailscale 登录。
6. 不需要改 `consoleHost`：设备服务本来就监听 `0.0.0.0:3101`。

#### 备选：Cloudflare Tunnel（有域名就能用）

1. `winget install --id Cloudflare.cloudflared`。
2. 临时域名（重启就变，只适合试）：
   ```
   cloudflared tunnel --url http://127.0.0.1:3101
   ```
   把打印出来的 `https://xxx.trycloudflare.com` 填进 App 的 tunnel 通道。
3. 永久隧道：`cloudflared tunnel login` → `cloudflared tunnel create xiaobeiming` → 子域名 CNAME 到 `<tunnel-id>.cfargotunnel.com` → `cloudflared tunnel route dns xiaobeiming phone.example.com` → `cloudflared tunnel run xiaobeiming` → `cloudflared service install` 做成服务，避免关终端就断。
4. **必须**保留设备令牌鉴权（App 每个请求都带 `x-device-token`）。想更稳一层：Cloudflare Zero Trust 里给域名套 **Access**（只允许你的邮箱登录），别人连页面都打不开。
5. 代价：流量绕 Cloudflare，免费版对长连接没 SLA；长轮询 25 秒一般没事，网络抖动时切换会比 Tailscale 频繁。

#### 安全须知（暴露到公网之后）

- **弱令牌等于把她的眼睛和耳朵交给别人。** 设备令牌至少 32 字符随机；自动生成的 `state/device/token` 满足这个强度，自己写 `config.json` 的照同样强度来。
- 轮换：删掉 `state/device/token` 重启桥接（或改 `config.json` 的 `device.token`），所有手机重新填一次。
- 丢手机：`GET http://127.0.0.1:3100/api/device/devices`（带主控 token）看所有配对设备；`POST /api/device/devices/revoke` body `{"deviceId":"..."}` 立刻吊销那台。
- 设备接口每台设备 **120 次/分钟**、图片 **≤8MB**，超了回 429，不会无限烧流量。
- **别把主控 token 填进手机**：拿它访问 `/api/device/*` 会被拒（401 `CONSOLE_TOKEN_FORBIDDEN`），这是故意的。
- `consoleHost` 默认 `127.0.0.1`；确实要从别的机器看控制台再改成 `0.0.0.0`。

### "开启后台音频"

**不需要在系统设置里开任何开关**——`UIBackgroundModes = audio` 已经写进 `Info.plist`，装好即生效。要做的是别让系统提前掐死它：

- **设置 → 电池 → 低电量模式：关闭**（低电量模式会限制后台音频）
- **设置 → 通用 → 后台 App刷新 → 小北冥：打开**
- **不要上滑杀掉「小北冥」**；杀掉一次就要重新打开 App
- 手机锁屏、放口袋里都行，但**别让它长期处于过热/内存吃紧状态**（相机会话本身吃内存）
- 想让保活更稳：插着电、屏幕朝下放着

---

## 6. 7 天续签怎么办

免费证书 7 天失效，失效后 App 一打开就闪退。三种办法：

### 方案 A：AltServer 自动续签（推荐，全自动）

1. AltServer 保持**开机自启 + 托盘常驻**（AltServer 设置里勾 Launch at Login）。
2. 手机 AltStore → **Settings → 打开 Refresh Apps Over Wi-Fi**，并确认里面能看到这台电脑。
3. 手机和电脑**同一 WiFi**，AltStore 会在后台每 24 小时左右自己刷新一次签名。
4. 想手动确认：AltStore → My Apps → 下拉刷新，看到「小北冥」旁边的时间变成 7 天后即成功。

> 自动续签依赖：电脑醒着、AltServer 在跑、同一局域网、手机没关「后台 App刷新」。
> 出差/断网超过 7 天就会过期，回来连上 WiFi 打开 AltStore 手动 Refresh 一次即可。

### 方案 B：SideStore（不用电脑常开）

SideStore 用 StosVPN 在本机完成签名刷新，不需要 AltServer 常驻；安装流程更绕（需要先装 SideStore 的 ipa、配对文件等），但续签可以在手机上独立完成。适合电脑不常开的场景。

### 方案 C：付费开发者账号（$99/年）

证书 1 年有效，不用 7 天续签，也没有 3 个 App 的上限。仍然走 AltStore 安装，只是登录的是付费账号。

---

## 7. 常见失败排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| App 一启动就闪退 | 没开开发者模式 / 证书已过期 | 设置→隐私与安全性→开发者模式 打开并重启；AltStore 里 Refresh |
| 状态一直是「未配置 token」 | 设置没保存或 token 为空 | 重新填 IP/端口/token，点保存并重连 |
| 「断线（1s 后重连）」循环 | IP 错、端口不是 3101、防火墙拦了 | 电脑上 `curl http://<IP>:3101/api/device/status?token=<token>` 自查；放行防火墙 |
| `curl 127.0.0.1:3101` 通、手机不通 | 手机不在同一网段 / 路由器 AP 隔离 | 关掉路由器的「AP 隔离」，确认手机 WiFi 的 IP 前三段一致 |
| `{"ok":false,"code":"UNAUTHORIZED"}` | token 不对 | 重新 `type state\device\token`，注意别多复制空格/换行 |
| `CONSOLE_TOKEN_FORBIDDEN` | 把主控 token 填进了手机 | 手机要用 `state\device\token`，主控 token 只留在电脑上 |
| `DEVICE_REVOKED` | 这台设备被吊销过 | 吊销不可逆：要重新启用得手动编辑 `state\device\devices.json`（删掉那条记录或把 `revoked` 改回 false）再重启桥接 |
| 「所有通道都连不上」 | 三条都不通 | 电脑上 `curl -H "x-device-token: $t" http://<IP>:3101/api/device/ping`；lan 只在同一 WiFi 有效，出门要开 Tailscale |
| 出门后 `lan:不通` 但没切到 tailscale | Tailscale 没连 / On-Demand 没开 | 打开 Tailscale 确认已登录已连接；App 连续 3 次失败会自己切，也可以「保存并重连」强制重新探测 |
| 一直卡在「所有通道不可达，30 秒后重试」 | 全断后的冷却期 | 等 30 秒会自动重新探测；着急就点大按钮待机→唤醒 |
| 指令发出去但手机没反应 | App 在后台被系统挂起了 | 打开 App 到前台；确认没开低电量模式；确认「后台 App刷新」开着 |
| 拍照全黑 | 相机权限被拒 / 手电筒模式冲突 | 设置→小北冥→相机 打开；重开 App |
| 录音文件很小 / `silent=true` | 环境真的安静，或麦克风权限被拒 | 正常现象；权限问题去 设置→小北冥→麦克风 |
| `say` 没声音 | 手机静音开关 / 音量 0 / 音频 URL 手机拿不到 | 检查音量；确认手机能访问 `http://<IP>:3101/api/device/audio/...`（音频 URL 里带 token） |
| 震动没反应 | App 在后台（CoreHaptics 后台会停）或设备不支持 | 到前台再试；老设备会走 `UIImpactFeedbackGenerator` 兜底 |
| `openApp` 报「App 在后台，iOS 不允许…」 | 系统限制 | 把 App 切到前台再让它开 App；这是 iOS 的硬限制，不是 bug |
| AltServer 连不上手机 | iTunes/iCloud 是 Microsoft Store 版 | 卸掉，装 Apple 官网版；重插数据线并「信任」 |
| 续签失败 `AltServer not found` | 电脑休眠/AltServer 没跑/不同 WiFi | 唤醒电脑、确认托盘图标在、连同一 WiFi |

---

## 8. 安全边界（写进代码，不是口号）

- **没有**任何定时/后台偷拍偷录：`look` / `listen` 只能由桥接下发的指令触发。
- 每次 `look` / `listen` **执行前**先显示屏幕顶部黄色横幅，停留 0.7 秒后才动硬件，结束后保留 3 秒。
- 每一条指令都在 `Documents/../Library/Application Support/XiaoBeiMing/device-log.jsonl` 留一条本地记录（含时间、指令、成功与否、元信息；不存媒体正文）。
- 桥接侧限流：`look` 每分钟最多 6 次、`listen` 每分钟最多 2 次，超出直接报 `RATE_LIMITED`。
- **不实现**：指纹/面容、短信/通讯录、模拟点击别的 App、静默上传相册、定位。
- 未配置 token 时 App 不发起任何连接；服务端所有 `/api/device/*` 都要 token，且用 timingSafeEqual 比较。
- **令牌分离**：主控 token 不能用于设备接口（回 401 `CONSOLE_TOKEN_FORBIDDEN`），设备令牌也不能看控制台。配对后每台设备一个独立令牌，桥接只存 sha256，可单台吊销。
- **设备限流**：每台设备每分钟 ≤120 次请求，图片 ≤8MB；超了回 429 并带 `retry-after`。
- 设备接口的所有响应都不回显 token / tokenHash（`GET /api/device/status` 里只有设备名、在线、通道、电量）。
- 远程接入不会自动开公网端口：默认走 Tailscale；用 Cloudflare Tunnel 时至少要保留设备令牌鉴权，建议再套 Cloudflare Access。

---

## 9. 已知限制（别期待 iOS 给不了的东西）

1. 后台保活不是 100%：内存压力、低电量模式、手动上滑、系统重启都会断，需要重新打开 App。后台**收音**比保活更苛刻：必须同时有音频输出（静音循环也算），否则系统 30 秒内就挂起。
2. 后台时 CoreHaptics 不工作；后台也不能 `openApp`（iOS 限制）。
3. 不能自动化别的 App 界面（没有 WDA/越狱）；只能 URL Scheme 跳到某个 App，或用快捷指令/分享扩展。
4. `listen` 指令默认在手机端上识别成文字（WhisperKit，音频不出手机）；模型没准备好或识别失败时才回退上传音频、由桥接转写。实时通道的音频片段仍会落成 wav，桥接按队列转写（见第 10、11 节）。
5. 首次连局域网时 iOS 会弹「本地网络」权限，拒了之后要 设置→隐私与安全性→本地网络 里手动打开。

---

## 10. 实时感官通道（P1：常驻听 + 她说你听）

### 10.1 链路长什么样

```
iPhone 麦克风
  → AVAudioEngine 采集（硬件采样率）
  → 线性重采样到 16 kHz 单声道 PCM16
  → WS 二进制帧（40 ms 一帧，1280 字节）
  → 桥接 ws://<电脑>:3102/api/sense/audio?token=<设备令牌>
  → 每 10 秒或 speech_end 落一个 wav 到 state/sense/
  → （后续）STT → 她 → TTS → 沿同一条 WS 下发 say / audioUrl
  → 手机 SpeechService 播放（克隆音色走 audioUrl，纯文本走系统 TTS）
```

- 端口 **3102**（config.json 的 sense.port 可改），和指令接口 3101 分开：长连接升级和短轮询混在一个端口上排查太痛苦。
- 帧协议：文本帧是控制 JSON（hello / heartbeat / speech_start / speech_end / say / state），二进制帧是裸 PCM。
- 鉴权与 /api/device/* 同一枚设备令牌；主控令牌打过来是 401 CONSOLE_TOKEN_FORBIDDEN。
- Windows 防火墙要把 3102 也放行（同 3101 的做法）。

### 10.2 为什么是 PCM 不是 Opus

需求里建议 Opus，但 **iOS 系统框架没有 Opus 编码器**（AudioToolbox 只有 AAC/ALAC/ILBC 等），项目又不允许引第三方库。所以 P1 用未压缩的 PCM16：

| 方案 | 依赖 | 流量（单向） | 延迟 |
| --- | --- | --- | --- |
| PCM16 16k | 零 | ≈256 kbps | 最低 |
| Opus 24 kbps | 需要 libopus（违反"不加第三方库"） | ≈24 kbps | 稍高 |

P1 选前者；真要省流量，下一阶段可以改成 AAC（系统原生支持）或解禁第三方库后用 Opus。

### 10.3 三件绕不过去的系统限制（别当成实现遗漏）

1. **后台常听必须有音频输出**：AVAudioSession 用 .playAndRecord，再叠 UIBackgroundModes: audio 和 KeepAlive 的静音循环。纯录音的 session 在切后台约 30 秒后会被系统挂起。
2. **后台不能开摄像头**：这是系统硬限制（不是权限问题）。"眼睛"只在两种情况下工作：App 在前台（支架充电值班）、或她/主人触发一次 look 把 App 唤起来拍一张。代码里**没有**后台偷拍路径。
3. **打断（barge-in）只能半双工**：手机端 VAD 检测到主人开口 → 立刻停 TTS、这一小段不上行（防回声）。真正的 AEC 需要 WebRTC 那套，不在 P1 范围。

### 10.4 VAD 与功耗策略（手机本地判断，不把静音往上传）

- 上行前先算 RMS：低于阈值就当没人说话，**不上行**，只每 5 秒发一个 heartbeat 控制帧（服务端统计为 silentHeartbeats）。
- 省电模式或电量 < 20%：采样降到 8 kHz、VAD 阈值提高到 0.035、心跳放宽到 10 秒。
- 充电 + 前台：16 kHz 全速。
- 断线：1s / 3s / 9s 三次退避重连；全失败后等 30 秒再来一轮，避免死循环耗电。

### 10.5 桥接侧怎么用

```powershell
# 看有没有手机连上来（会话、帧数、已收到多少秒、功耗档位）
curl.exe -s -H "x-console-token: <主控token>" http://127.0.0.1:3100/api/sense/status

# 让她借手机喇叭说一句（纯文本走手机本地 TTS）
curl.exe -s -X POST -H "x-console-token: <主控token>" -H "content-type: application/json" 
  --data-binary "@say.json" http://127.0.0.1:3100/api/sense/say     # {"text":"我在听"}

# 状态流：thinking / tool / replying 会实时推给手机界面
curl.exe -s -X POST -H "x-console-token: <主控token>" -H "content-type: application/json" 
  --data-binary "@state.json" http://127.0.0.1:3100/api/sense/state   # {"state":"thinking","detail":"在查天气"}

# 收到的音频片段（10 秒一片，16k 单声道 wav）
dir C:\Users\zwc\qq-bridge\state\sense
```

Windows PowerShell 5.1 里用 curl.exe -d '{...}' 会被剥掉双引号变成 BAD_JSON，务必先把 JSON 写进文件再 --data-binary "@file"。

### 10.6 还没做的（如实写）

- **常驻通道的片段会转写，TTS 已接**：wav 片段由桥接的串行转写队列（`drainTranscribe`）处理，`say` 走手机本地 TTS 或 7880 克隆音色。真正没验证的是端到端延迟与真机后台续航（见下一条）。`listen` 指令默认改走手机端上识别，只有模型未就绪/识别失败才回退上传音频。
- **P1 的三条验收指标全部未验证**（没有真机）：后台锁屏连续 30 分钟不中断、20 次延迟中位数 < 2.5s、连续 1 小时耗电。代码与桥接侧都能在 Windows 上跑通，但真机数据只能等装上去之后测。
- 二进制的**下行**音频（服务端直接推 PCM 给手机播）协议留了位置，P1 没实现；现在说一句走的是 say 文本帧 + 手机本地 TTS，或 udioUrl 让手机下载播放。

---

## 11. 端上识别（A15）

### 11.1 链路

```
listen 指令
  → MicService 录音（16 kHz 单声道 wav；VAD 800–1000 ms 静音自动收尾，上限仍是 seconds）
  → OnDeviceASR.transcribe（WhisperKit + CoreML，audioEncoder / textDecoder 走神经引擎）
  → DeviceController 把文字 POST 到 ws 同端的 3102 /api/sense/utterance
  → 桥接写 state/sense/utterances.jsonl，并回传 sttSource=device / sttMs / model
  → 指令结果里不带 media：音频没有离开手机
```

失败兜底：模型未就绪、转写抛错、或识别结果为空 → 仍把这段 wav 作为 `media` 回传，桥接照旧调用 `transcribeLocalAudioDetailed`，返回 `sttSource=server`。这条旧路径没有改。

### 11.2 SwiftPM 依赖

| 项 | 值 |
| --- | --- |
| 包地址 | `https://github.com/argmaxinc/WhisperKit`（仓库已重定向到 `argmaxinc/argmax-oss-swift`） |
| 版本 | **精确 0.9.0**（`exactVersion: 0.9.0`；不要用 1.x，API 有变动） |
| 平台 | iOS 16.0+；建议 Xcode 16 编译（包内 swift-tools 5.10） |
| Product | `WhisperKit` |

`project.yml` 里已经写好：

```yaml
packages:
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    exactVersion: 0.9.0
# target XiaoBeiMing:
dependencies:
  - package: WhisperKit
```

`xcodegen generate` 后 Xcode 会自动解析。手工添加也行：File → Add Package Dependencies… → 粘贴 URL → Dependency Rule 选 **Exact Version 0.9.0** → 加到 `XiaoBeiMing` target。

### 11.3 Info.plist / 能力清单

| 键 | 状态 | 用途 |
| --- | --- | --- |
| `NSMicrophoneUsageDescription` | 已有，文案补充「默认在手机本地识别成文字，音频不上传」 | 录音 + 端上识别 |
| `UIBackgroundModes` = `audio` | 已有 | 后台保活 / 常驻听；不是给 ASR 无限跑用的 |
| `NSLocalNetworkUsageDescription` | 已有 | 连 3101 / 3102 |
| `NSAppTransportSecurity`（允许本地网络） | 已有 | 局域网 http/ws |
| `ITSAppUsesNonExemptEncryption` = `false` | **新增** | 出口合规，省掉每次上传的加密问卷 |

不需要新的 entitlement，也不需要单独的网络权限：模型和 tokenizer 走 HTTPS，第一次下载时系统只弹本地网络/麦克风（如尚未授权）。

### 11.4 模型体积与内存

| 模型 | 磁盘（权重合计） | 峰值内存（估算） | 说明 |
| --- | --- | --- | --- |
| `small` | ≈484 MB | 0.7–1.0 GB | 默认；准确率最好，A15 上 2 s 音频目标 ≤1.2 s 属于**目标值，需真机实测** |
| `base` | ≈146 MB | 0.3–0.4 GB | small 下载/加载失败时自动回退 |
| `tiny` | ≈76 MB | ≈0.15 GB | 最后兜底；准确率明显下降 |

- 存放位置：`Application Support/XiaoBeiMing/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>`。删 App 才会清掉；不想占空间可在设置里换 tiny 后手动删除旧目录。
- **tokenizer 单独下载**：WhisperKit 的 `loadTokenizer` 从 HuggingFace `openai/whisper-<variant>` 取 `tokenizer.json`（几 MB），首次识别需要联网；`tokenizerFolder` 指向同一个 Models 目录，之后走缓存。
- 首次加载会做 CoreML 预编译（`prewarm: true`），可能几十秒；设置页有进度和「准备模型」按钮，别在 `listen` 指令里等下载。
- 内存压力：`small` 峰值接近 1 GB，低内存设备/后台被 jetsam 时识别会失败并自动回退上传音频。

### 11.5 为什么不能在后台无限跑

- iOS 的后台音频（`UIBackgroundModes: audio`）只在音频会话**持续有 I/O**时给执行时间；`KeepAlive` 的静音循环能保住进程，但那是为了麦克风和播放，不是给推理开无限 CPU。
- Whisper 推理是一段 ANE/CPU 突发；App 退到后台且没有录音/播放时，系统约 30 秒内就会挂起，正在跑的推理可能被中断。所以端上识别只在「一次 listen / 前台/常驻听活跃」期间做，**不要指望它在后台连续转写几个小时**。
- 模型下载也没有用后台下载 session（`useBackgroundDownloadSession: false`）：首次下载请在前台、充电、Wi-Fi 下做。
- 真要在后台长跑，只能靠 audio session 持续保活（例如常驻听），代价是耗电和麦克风常开；这属于 P1 常驻通道的取舍，不是 ASR 能绕开的。

### 11.6 开关与回退

- 设置页「端上识别（A15）」：`useOnDeviceASR`（默认 **true**）、模型（默认 `small`）、静音收尾 800–1000 ms 可调。
- 持久化：`AppSettings` → `UserDefaults` key `app.settings.v1`。
- 指令参数 `onDeviceASR: false` 可强制走服务端；此外模型未就绪 / 转写异常 / 空文本也会自动回退。
- 回退时音频照常上传，桥接返回 `sttSource=server`；端上成功时返回 `sttSource=device` 且 `mediaPath=null`。
- 不想用端上识别：设置页关掉开关，或把 `onDeviceASR` 传 false；服务端转写路径与 QQ 语音条完全不受影响。

### 11.7 桥接接口

设备面（3102，设备令牌）：

```powershell
curl.exe -s -X POST -H "x-device-token: <设备token>" -H "content-type: application/json" `
  --data-binary "@utt.json" http://127.0.0.1:3102/api/sense/utterance
# utt.json: {"text":"今天下午三点开会","ms":870,"model":"small","durationSec":2.4,"source":"device","sessionId":"..."}

curl.exe -s -H "x-device-token: <设备token>" "http://127.0.0.1:3102/api/sense/utterances?limit=5"
```

管理面（3100，主控令牌）同样有 `POST /api/sense/utterance` 与 `GET /api/sense/utterances`，方便脚本回归。写入 `state/sense/utterances.jsonl` 的字段与音频片段对齐：

```json
{"file":null,"durationSec":2.4,"transcript":"今天下午三点开会","at":"2026-10-29T15:38:27.011Z","ms":870,"source":"device","sttMs":870,"model":"small","sessionId":"..."}
```

文字事件**不会**再进 `drainTranscribe` 队列（已经识别过了）；空文本返回 400 `EMPTY_TEXT`，超长（>8000 字）返回 400 `TEXT_TOO_LONG`。

### 11.8 构建与静态验证

```powershell
cd C:\Users\zwc\qq-bridge\ios
xcodegen generate
open XiaoBeiMing.xcodeproj   # 选 Team / 真机，Run
```

`project.yml` 里 `CODE_SIGNING_ALLOWED=NO`，真机运行前在 Xcode 的 Signing & Capabilities 里选自己的 Team（bundle id `com.xiaobeiming.senses` 可按需改）。

**当前没有 Mac，也没有编译过**，只做了静态检查：

```powershell
node scripts/check-ios-sources.mjs
# 101 通过 / 0 失败（13 个 Swift 文件）
```

新增 API 的完整签名列在 `ios/REPORT.md`。真机第一次跑请这样验：

1. 设置页点「准备模型」，看到下载进度到 100%，状态变「已就绪 · small」。
2. 触发一次 `phone_listen`，Xcode 控制台搜 `[ASR]`，应出现 `audio=...s stt=...ms chars=...`；这就是 A15 的实测耗时。
3. `GET /api/sense/utterances?limit=5` 应看到 `source=device`；若看到 `sttSource=server` 且 `mediaPath` 非空，说明走了兜底，查设置页的 `lastError`。