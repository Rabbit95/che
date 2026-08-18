# Nikon Z Control

Flutter 跨平台 App（当前主线 Android + 桌面，iOS 后续），控制尼康 Z 系列微单：
浏览+下载相机文件、遥控快门、读写相机参数、实时 Live View。目标是 Wi-Fi 和 USB 双通道全支持。

完整背景、需求边界、技术选型和分阶段交付计划见 [PLAN.md](PLAN.md)；配套 UI 视觉稿见
[ui-mockups/index.html](ui-mockups/index.html)。

---

## 当前实际可用范围（更新于 2026-08-18，M3 完成 + USB transport 硬化 + M4 主线走通）

真机验证：**STF AL00（Android 9）+ Nikon Z 系列 USB 直连**已成功握手完成，遥控快门/参数写入/录像启停真机跑通。

| 功能 | 状态 | 说明 |
|---|---|---|
| 相机发现（USB） | ✅ 可用 | 2s 轮询 `getDeviceList` + Nikon VID/PID 匹配；插入相机 Android 弹权限对话框允许后自动出现在列表 |
| 相机发现（Wi-Fi mDNS） | 🟡 占位 | 列表里有一张固定假卡；bonsoir 依赖已在 pubspec，但 provider 里未接 |
| 连接握手 | ✅ 可用 | 真实 PTP-USB / PTP-IP 握手 + OpenSession + GetDeviceInfo + ChangeApplicationMode(1) + DeviceReady 轮询；日志逐条流式显示 |
| 错误诊断 | ✅ 可用 | 错误 log 显示 opcode 名 + response code 名 + 中文排障提示（AccessDenied / SessionAlreadyOpen / DeviceBusy 等） |
| Live View 屏 UI | ✅ 可用 | HUD/曝光条/AF 框/直方图/波形图/快门键/模式切换全部按 mockup 实装 |
| Live View 相机帧 | ✅ 可用 | `startLiveView` + `getLiveViewImageEx` 30 Hz 自调度循环；`LiveViewFrameCodec` 按 JPEG SOI 拆头 + JPEG，尽力解析图像宽高/AF 框；`Image.memory(gaplessPlayback: true)` 渲染；HUD 上 fps 显示滚动窗口测量值。**Wi-Fi 和 USB 通道共用同一条管线**（`NikonZClient` → `PtpSession` → `Transport` 抽象），USB 下无需额外代码即可跑，实测 fps 通常显著高于 Wi-Fi |
| Live View 点击对焦 | ✅ 可用 | LV 面板 tap → 按当前帧宽高把屏幕坐标缩放成 LV 像素 → `ChangeAfArea(x,y)` + `AfDrive`；AF-out-of-focus 静默降级，其它错误弹 SnackBar；同样对 Wi-Fi 和 USB 通用 |
| 参数抽屉屏 UI | ✅ 可用 | 底部 sheet + 滚轮预览 + 参数列表；已接真值（M2 完成） |
| 参数读 | ✅ 可用 | `cameraPropertiesProvider` 500ms 事件驱动 + 兜底轮询，抽屉 + 顶部 ExposureBar 同步更新；`PropFormatter` 覆盖 ISO/快门/光圈/EV/WB/AF/曝光模式/驱动/电量/焦距/闪光/测光 |
| 参数写 | ✅ 可用 | 抽屉行 tap → 枚举 sheet / range slider；EnumForm 全部走通，RangeForm 支持 int 类；`CameraCommands.setProperty` 统一封装错误并给中文排障提示 |
| 遥控快门 | ✅ 可用 | 快门键 tap → `capture()` + DeviceReady 轮询；haptic + SnackBar 反馈；in-flight 期间按钮变半透明避免二次触发 |
| 遥控录像 | ✅ 可用 | 视频模式下快门键 tap → `startMovieRecording/stopMovieRecording`；HUD 秒级计时；录像期间锁定模式切换 |
| Gallery | ❌ 未接 | 缩略图是渐变假图；`getObjectHandles + getThumb` 未接 |
| Transfer 队列 | ❌ 未接 | `downloadObject` 分片实装完成但未接 UI；写系统相册（photo_manager）未接 |
| iOS USB | ❌ 未做 | `IccTransport` 只是 stub；ICCameraDevice Pigeon 桥未写 |

**协议层 81 个单元测试全绿**：LE reader/writer、PTP-IP 14 种包 encode/decode 往返、PTP-USB container、
PTP 数据结构（DeviceInfo/StorageInfo/ObjectInfo/DevicePropDesc）、PacketFramer 跨 chunk 重组、
`PropFormatter` 21 个属性格式化用例、`LiveViewFrameCodec` 10 个用例（JPEG SOI 定位、AF 框/焦点区解析、
短包/空包/坏时间戳兜底）、`NikonZClient.tapToFocus` + `getLiveViewFrameDecoded` 7 个用例。
**App 层 26 个 provider 测试**覆盖 `cameraPropertiesProvider` 的初始读、事件驱动 refresh、兜底轮询、取消清理（9 个），
`CameraCommands` 的 capture/start-stop movie/setProperty 分发 + 中文排障提示映射（11 个），
以及 `runLiveView` 状态机（starting→running→frame、start 失败、单帧错误恢复、cancel 收尾 stopLiveView、
FPS 滚窗计算、warmup null 帧静默跳过）6 个用例。

---

## Repo 结构

```
D:\rabbit\code\che\
├── PLAN.md                            # 需求 / 技术选型 / 里程碑 / 进度快照
├── README.md                          # 本文件
├── pubspec.yaml                       # workspace 根 + dependency_overrides
├── melos.yaml                         # 跨包脚本
├── analysis_options.yaml
├── app\                               # Flutter 主应用
│   ├── lib\
│   │   ├── main.dart, app.dart, router.dart
│   │   ├── features\
│   │   │   ├── discovery\             # Screen 1 + 2（发现 + 引导）
│   │   │   ├── connection\            # Screen 3（连接握手 + Controller）
│   │   │   ├── control\               # Screen 4-6（Live View + 参数抽屉）
│   │   │   └── gallery\               # Screen 7-8（图库 + 传输队列）
│   │   └── shared\
│   │       ├── theme\app_theme.dart   # AppColors/AppTypography/AppRadius
│   │       ├── providers\             # Riverpod 顶层 providers
│   │       └── widgets\               # ChannelBadge / HudChip / PillButton / SignalBars
│   └── android\
│       ├── app\src\main\
│       │   ├── AndroidManifest.xml    # USB_DEVICE_ATTACHED intent-filter
│       │   └── res\xml\device_filter.xml  # Nikon Z 全系 VID/PID
│       ├── app\build.gradle.kts       # compileSdk = 36
│       └── build.gradle.kts           # subprojects hook: namespace 修补 + compileSdk 强制
├── packages\
│   ├── nikon_ptp\                     # 纯 Dart PTP / PTP-IP / PTP-USB 协议实现
│   │   ├── lib\src\{constants,model,codec,errors,transport,session,client}\
│   │   └── test\unit\                 # 64 个单元测试
│   ├── nikon_ptp_flutter\             # Flutter 侧 transport 实现
│   │   └── lib\src\
│   │       ├── ptpip_transport.dart   # Wi-Fi (dart:io Socket ×2)
│   │       ├── usb_transport.dart     # Android USB (quick_usb bulk 端点)
│   │       ├── icc_transport.dart     # iOS stub（M6b 待做）
│   │       ├── usb_discovery.dart     # USB 设备轮询
│   │       ├── nikon_usb_ids.dart     # Nikon VID/PID 表
│   │       └── client_guid_store.dart # 持久化 client GUID
│   └── quick_usb_patched\             # quick_usb 0.4.0 的本地 fork（Android 补丁）
├── tools\
│   └── ptp_replay_server\             # （空目录，CI 用的 PTP-IP 字节回放服务器待建）
└── ui-mockups\
    └── index.html                     # 8 屏 v0.1 设计稿（暗色 + 琥珀）
```

---

## 上手开发

### 前置

- Flutter 3.24+ 和 Dart 3.6+
- Android Studio + Android SDK Platform 36（quick_usb / photo_manager / shared_preferences 都要求）
- Java 17（Android Studio 自带 `jre17`）
- 真机（USB 直连相机需要 USB Host 能力，绝大多数 Android 手机支持）

### 一键跑（首次）

```bash
cd D:\rabbit\code\che\app
flutter pub get              # 会自动拾取 quick_usb 的本地 fork
flutter build apk --debug    # 首次约 40s，会下载 SDK 36
flutter install -d <device>  # 装到手机
```

也可以直接 `flutter run -d <device>`（会启动 REPL）。

### 单元测试（不需要真机）

```bash
cd D:\rabbit\code\che\packages\nikon_ptp
dart test
```

期望：`+64: All tests passed!`

App 层的 provider 测试（不需要真机也不需要 Android SDK）：

```bash
cd D:\rabbit\code\che\app
flutter test test/camera_properties_provider_test.dart test/camera_control_provider_test.dart
```

期望：`+20: All tests passed!`

### 相机侧准备（USB 路径）

1. 相机 `MENU → 设置 → USB 连接模式` → 选 **MTP/PTP** 或 **PC**（**不要**选 iPhone / MobileApp 模式）
2. 关闭相机的 Wi-Fi / 蓝牙 / FTP（避免和 USB 抢占 vendor 命令）
3. 相机停在主界面（不在录像 / 回放 / 菜单里）
4. USB-C 线接手机 ↔ 相机；插上时 Android 弹权限对话框选 **允许**

---

## 关键设计要点

- **协议包纯 Dart**：`packages/nikon_ptp` 不依赖 Flutter，方便桌面复用和 headless 单测。
- **Transport 抽象**：`PtpIpTransport`（Wi-Fi）/ `UsbTransport`（Android）/ `IccTransport`（iOS stub）
  三实现共用同一 `Transport` 接口，`PtpSession` 和 `NikonZClient` 上层完全对通道无感知。
- **PTP-USB vs PTP-IP 编解码分离**：`PtpIpCodec` 是长度前缀 + 14 种包类型；`PtpUsbCodec` 是
  12B container header（USB Still Image Class 1.0）。两个 codec 各有黄金字节向量单测。
- **串行 + 优先级队列**：PTP 一次一命令。`OperationQueue` 用最小堆保证 cancel/keepalive > 快门/写属性 >
  读属性/事件轮询 > LV 帧 > 后台传输。
- **暗色 + 琥珀 UI**：色板/字体在 [app/lib/shared/theme/app_theme.dart](app/lib/shared/theme/app_theme.dart)，
  与 [ui-mockups/index.html](ui-mockups/index.html) 严格对齐。
- **错误可诊断**：`ConnectionController` 把 `PtpResponseException.opcode` + `code` 拼成
  "GetDeviceInfo (0x1001) 失败: AccessDenied — 相机不允许进入控制模式..." 而不是裸 `0x2001`。
  运行时的相机命令（拍摄/写参数/录像启停）走 `CameraCommands` 门面，把同样的错误映射成
  `CameraControlFailure.userMessage` 直接喂给 SnackBar。
- **USB 不阻塞主线程**：`quick_usb_patched` 的 Kotlin 侧把 `UsbDeviceConnection.bulkTransfer`
  和 `controlTransfer` 挪进单线程 `Executors.newSingleThreadExecutor("quick_usb-io")`，结果
  用 `Handler(Looper.getMainLooper()).post` 切回主线程回调 `MethodChannel.Result`。相机 30s
  不回不会再导致 Android ANR。

---

## 已知坑与绕法

| 坑 | 表现 | 绕法 |
|---|---|---|
| pub 上 `quick_usb 0.4.0` 引用 API 31 符号但只声明 `compileSdkVersion 30` | `Unresolved reference 'S'` / `FLAG_MUTABLE` | 走 [packages/quick_usb_patched](packages/quick_usb_patched)（Kotlin 换数字字面量 + build.gradle 升 34），根 pubspec `dependency_overrides` 已配置 |
| `quick_usb` 上游把同步 `UsbDeviceConnection.bulkTransfer` 直接跑在 `onMethodCall` 里（Android UI 主线程），相机 30s 内不回就 ANR | 相机连接卡住直到 `PlatformException(unknown, bulkTransferOut error)` | fork 里加了 `Executors.newSingleThreadExecutor("quick_usb-io")`，bulk IN/OUT 和 clearHalt 全部挪到后台线程，结果通过 `Handler(Looper.getMainLooper())` 切回主线程 |
| 前一次 session 崩溃留下 bulk 端点 halt，新一次连接第一个 bulkTransferOut 卡到超时 | 首次连接必超时 | fork 里新增 `QuickUsb.clearHalt(endpoint)`（走 CLEAR_FEATURE(ENDPOINT_HALT) control transfer），`UsbTransport.open()` claim interface 之后对 bulk-IN/OUT 各做一次 best-effort clearHalt |
| Kotlin 增量 cache 跨盘符（pub cache 在 C:、项目在 D:）报 `IllegalArgumentException: different roots` | Gradle 编译死 | [app/android/gradle.properties](app/android/gradle.properties) 里 `kotlin.incremental=false` |
| Android 系统 MTP 服务先 claim 走相机 | 首次连接 `claim interface 失败` | 拔插相机一次；后续加 retry |
| Windows PowerShell 5 不支持 `&&` | `dart pub get && dart test` 报语法错 | 分开两行 / 装 PowerShell 7 |
| iOS 平台目录未生成 | 无法 `flutter build ios` | `cd app && flutter create . --platforms=ios` 首次生成，然后按 PLAN §"如何运行在真实的 iOS 设备上"配 Info.plist |

---

## 参考

- [libgphoto2 `camlibs/ptp2`](https://github.com/gphoto/libgphoto2/tree/master/camlibs/ptp2) —
  `ptp.h` 常量表 + 事务状态机是 clean-room 重实现的规范参考
- [laheller/ptplibrary](https://github.com/laheller/ptplibrary) — 面向对象拆分模板
- ISO 15740（PTP）+ PIMA 15740 PTP-IP addendum + USB Still Image Class 1.0
