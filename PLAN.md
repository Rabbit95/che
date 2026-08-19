# Nikon Z 移动控制/传输 App —— 实施计划

## Context

目标：为个人/内部使用做一款 Flutter 跨平台（Android + iOS）App，控制 Nikon Z 系列微单相机（Z5/Z6/Z6II/Z6III/Z7/Z7II/Z8/Z9/Zf/Z50/Z50II），做四件事：**浏览+下载相机文件、遥控快门、读写相机参数、实时 Live View 监看**。**四件事都要求同时支持 Wi-Fi 和 USB 有线两种通道**（用户明确要求：有线 Live View 更稳、帧率更高，是差异化核心）。

平台细节：
- **Android**：Wi-Fi + USB Host（`UsbDeviceConnection` 裸调）
- **iOS (iPhone USB-C / iPad Lightning 或 USB-C)**：Wi-Fi + USB 均支持。iPhone USB 走 Apple 官方 `ImageCaptureCore.ICCameraDevice.requestSendPTPCommand`（iOS 13.2+ 起 iPhone 与 iPad 均支持外部 PTP 相机，同一 API；影控台 / Cascable Studio 走的都是这条路）
- **iPhone (Lightning 老机型)**：需要 Apple Camera Connection Kit，同样走 ImageCaptureCore

**为什么做**：

1. 官方 SnapBridge / NX MobileAir 长期体验薄弱、迭代慢、传输速度不理想。
2. 现有第三方方案各有欠缺：NikonLink（Kotlin，仅 Android，PTP-IP init 未完成，走 BLE 唤醒复杂）；影犀（Flutter，商业闭源，只走 Wi-Fi 无 USB）。
3. 尼康官方 Camera Remote SDK v2 只有 Windows/macOS/Linux 桌面版,移动端**没有官方 SDK**——只能基于公开的 PTP-IP 标准（ISO 15740）+ Nikon 厂商扩展 opcode 逆向实现。
4. 用户明确要求有线 Live View（更稳、帧率更高），这是本项目相对影犀的核心差异化。

**预期产出**：一款私有部署的 Flutter App，配套一个可独立复用的 `nikon_ptp` 纯 Dart 协议包（无 Flutter 依赖，未来可复用到桌面工具）。

---

## 确认的需求边界

| 维度 | 决策 |
|---|---|
| 平台 | Flutter，Android + iOS（iPhone USB-C 和 iPad 均支持 USB 直连相机） |
| Wake 策略 | **无 BLE**，用户手动在相机菜单开 Wi-Fi（不申请蓝牙权限） |
| 相机 USB 模式 | **必须设为 MTP/PTP**（标准 PTP class），不用 Nikon 私有的 `[iPhone]` 模式（那是 NX MobileAir 专用） |
| 功能范围 | **传输、遥控快门、参数读写、Live View — 四项功能均要求 Wi-Fi 和 USB 双通道全支持** |
| 机型 | 仅 Z 系列微单（不含 DSLR，不含 ZR/Z-Cinema） |
| 配对 | **MVP 假定已通过 SnapBridge 配对**，v2 再做 App 内配对 |
| RAW 处理 | **只用相机内嵌 JPEG 预览**（GetThumb + GetLargeThumb），不做 NEF 解码 |
| 下载存储 | **默认存到系统相册**（photo_manager 包） |
| 发布 | 个人/内部使用，不公开，不上应用商店 |

---

## 核心技术选型

| 层 | 选型 | 理由 |
|---|---|---|
| 语言/框架 | Flutter 3.x + Dart 3.6 workspaces | 单代码库跨 Android/iOS/iPad |
| 状态管理 | Riverpod 2 (code-gen) | `AsyncValue` 天然贴合 PTP 失败模式；Stream 对 Live View 友好 |
| USB (Android) | `flutter_quick_usb` (BSD-3) | 直接暴露 `bulkTransferIn/Out` + `claimInterface`，PTP-USB 原语齐全 |
| USB (iOS：iPhone + iPad) | 自写 Swift Pigeon 通道包 `ICDeviceBrowser` + `ICCameraDevice.requestSendPTPCommand` | iOS 13.2+ 起 iPhone 与 iPad **同一 API** 支持外部 PTP 相机 + 自定义厂商 opcode；无需 MFi；影控台 / Cascable Studio 走的都是这条路。**iOS 18+/26 新增 Wired Accessories 权限对话框**需要处理 |
| mDNS | `bonsoir` | 活跃维护，Android/iOS 均走原生 API，稳定 |
| 前台服务 / Wi-Fi 绑定 | 自写 Kotlin Pigeon 通道 | `ConnectivityManager.requestNetwork` + `bindProcessToNetwork` 是 Android 10+ 的救命 API，`quick_usb` 不管这块 |
| 相册写入 | `photo_manager` | 跨平台 Photos/MediaStore |
| PTP-IP / PTP-USB 协议实现 | **从零自写**（`packages/nikon_ptp`） | pub.dev 上零选择，只能自己写。以 libgphoto2 `camlibs/ptp2/*` 为规范参考（clean-room 从常量重实现，不复制代码） |

参考实现：[libgphoto2 主分支](https://github.com/gphoto/libgphoto2/tree/master/camlibs/ptp2)（`ptp.h`、`ptpip.c`、`ptp.c`、`library.c`、`config.c`）+ [laheller/ptplibrary](https://github.com/laheller/ptplibrary) 作为面向对象拆分模板。

---

## 架构分层

```
Presentation (Flutter + Riverpod)
    │
Application (use cases)
    │
Domain (entities, repository interfaces)
    │
NikonZClient          ← Z 系列高层 API（Client 提供 startLiveView/setISO 等语义方法）
    │
PtpSession            ← PTP 事务状态机（cmd → data → response，事件流分离）
    │
Transport (interface) ← 抽象传输
    ├── PtpIpTransport (dart:io Socket × 2, Wi-Fi 全平台通用)
    ├── PtpUsbTransport (Android, quick_usb bulk endpoints)
    └── IccPtpTransport (iOS — iPhone 与 iPad 共用, 走 platform channel 到 ICCameraDevice)
    │
Platform (Pigeon channels for Kotlin/Swift)
```

**关键决策**：协议层**拆成独立的 pub-workspace 包** `packages/nikon_ptp`，纯 Dart 零 Flutter 依赖，方便做 headless 单元测试和未来复用。Flutter 相关的 transport 实现放在 `packages/nikon_ptp_flutter`。

---

## 目录结构

```
D:\rabbit\code\che\
├── pubspec.yaml                          # Dart 3.6 workspace 根
├── melos.yaml                            # 多包脚本
├── PLAN.md                               # 本文件
├── app\                                  # 主应用
│   ├── lib\
│   │   ├── main.dart, app.dart
│   │   ├── features\
│   │   │   ├── discovery\                # 相机扫描/选择
│   │   │   ├── connection\               # 连接向导 + 状态
│   │   │   ├── control\                  # 参数面板 + 遥控快门
│   │   │   ├── liveview\                 # 实时监看 + AF 框
│   │   │   ├── gallery\                  # 相机内文件浏览 + 下载
│   │   │   └── settings\
│   │   ├── shared\{widgets,theme,providers}\
│   │   └── platform\                     # Pigeon 生成的 Dart bindings
│   ├── android\app\src\main\kotlin\      # WifiBinder, FgsHost, UsbHostImpl
│   ├── ios\Runner\                       # IccPtpPlugin.swift
│   └── test\
├── packages\
│   ├── nikon_ptp\                        # 纯 Dart 协议包
│   │   ├── lib\src\{codec,model,transport,session,client,constants,errors}\
│   │   └── test\{unit,golden}\
│   └── nikon_ptp_flutter\                # Flutter 侧 transport 实现
│       ├── lib\src\{ptpip_transport,usb_transport,icc_transport}.dart
│       └── pigeons\                      # Pigeon schema 源
└── tools\ptp_replay_server\              # CI 用的 PTP-IP 回放服务器
```

---

## 数据模型（`packages/nikon_ptp/lib/src/model/`）

- `PtpIpPacket` — 密封类，按包类型 1–14 分子类（InitCommandRequest/Ack、InitEventRequest/Ack、InitFail、CmdRequest/Response、Event、StartData/Data/EndData、Cancel、Ping/Pong）
- `PtpTransaction { transactionId, opcode, params[], dataOut?, response? }`
- `PtpResponse { code, params[] }`
- `DeviceInfo` — 标准版本、厂商扩展 ID/描述、支持的 operations/events/properties、格式列表、厂商/型号/固件/序列号
- `StorageInfo { id, type, fsType, access, maxCapacity, freeSpace, description, volumeLabel }`
- `ObjectInfo { storageId, format, protection, size, thumbFormat/W/H, imageW/H/bitDepth, parent, captureDate, filename }`
- `DevicePropDesc { propCode, dataType, getSet, factoryDefault, currentValue, formFlag, form(Range|Enum) }`
- `CameraEvent { code, transactionId, p1, p2, p3 }`
- `LiveViewFrame { jpeg: Uint8List, header: LvHeader (afRect/focusArea/histogram/exposure), ts }`
- `NikonZModel` enum + `NikonZQuirks` 按 model+firmware 的能力开关

---

## 协议常量（`packages/nikon_ptp/lib/src/constants/`）

### PTP-IP 包类型
```
InitCommandRequest=1, InitCommandAck=2, InitEventRequest=3, InitEventAck=4,
InitFail=5, CmdRequest=6, CmdResponse=7, Event=8, StartData=9, Data=10,
CancelTransaction=11, EndData=12, Ping=13, Pong=14
```
每个包 header = `uint32 length (LE)` + `uint32 type (LE)`。

### 标准 PTP opcode（用得到的）
```
GetDeviceInfo=0x1001, OpenSession=0x1002, CloseSession=0x1003,
GetStorageIDs=0x1004, GetStorageInfo=0x1005,
GetObjectHandles=0x1007, GetObjectInfo=0x1008, GetObject=0x1009,
GetThumb=0x100A, InitiateCapture=0x100E, GetPartialObject=0x101B,
GetDevicePropDesc=0x1014, GetDevicePropValue=0x1015, SetDevicePropValue=0x1016
```

### Nikon 厂商 opcode（Z 系列）
```
ChangeApplicationMode=0x9435  ← 【关键】Z 系列必须首先调用这个进入控制模式
DeviceReady=0x90C8            ← 命令后轮询相机是否就绪
GetVendorPropCodes=0x90CA
GetEventEx=0x941C             ← Z 系列事件轮询
StartLiveView=0x9201  EndLiveView=0x9202
GetLiveViewImageEx=0x9428     ← Z 系列 LV 帧
GetLiveViewImg=0x9203         ← 老机型 legacy fallback
AfDrive=0x90C1  MfDrive=0x9204  ChangeAfArea=0x9205  AfDriveCancel=0x9206
InitiateCaptureRecInMedia=0x9207  ← "拍到卡上"
StartMovieRecInCard=0x920A  EndMovieRec=0x920B  TerminateCapture=0x920C
GetObjectSize=0x9421  GetPartialObjectEx=0x9431  ← 64-bit offset/len
GetObjectsMetaData=0x9434
StartTracking=0x9424  EndTracking=0x9425  ChangeAELock=0x9426
```

### Nikon 事件码
```
ObjectAddedInSDRAM=0xC101, CaptureCompleteRecInSdram=0xC102,
PreviewImageAdded=0xC104, MovieRecordInterrupted=0xC105,
MovieRecordComplete=0xC108, MovieRecordStarted=0xC10A,
LiveViewStateChanged=0xC10C
```

### PTP-IP InitCommandRequest 字节布局
```
[0]  4B  length (LE)
[4]  4B  type = 1
[8]  16B GUID (客户端稳定 GUID，持久化到 shared_preferences)
[24] N   friendlyName UTF-16LE null-terminated
[24+N] 2B  protocol version minor = 0x0000
[26+N] 2B  protocol version major = 0x0001    ← minor 在前，major 在后（易踩坑）
```

InitEventRequest 固定 12B：`[length=12][type=3][ConnectionNumber from ack]`。

---

## Transport 抽象

`Transport` 接口（`packages/nikon_ptp/lib/src/transport/transport.dart`）：
```dart
abstract class Transport {
  Future<void> open(TransportConfig cfg);
  Future<PtpResponse> sendCommand(int opcode, List<int> params, {Uint8List? dataOut});
  Stream<Uint8List> receiveDataStream(int opcode, List<int> params);
  Stream<CameraEvent> get events;
  Future<void> close();
}
```

三个实现：
- `PtpIpTransport` — `dart:io` 双 Socket（cmd + event），完整 PTP-IP 握手
- `PtpUsbTransport` — Android 走 `quick_usb`，PTP-USB 三个 endpoint（Bulk-OUT/Bulk-IN/Interrupt-IN），事件通过 Interrupt endpoint 收
- `IccPtpTransport` — **iOS 全设备（iPhone + iPad）** 走 Pigeon 通道调 `ICCameraDevice.requestSendPTPCommand`；事件通过 `ICCameraDeviceDelegate` 回调转 Stream。**注意**：iOS 18+ 的 `mediaFiles` 空返回和 `requestControlAuthorization()` 卡在 `.notDetermined` 是已知回归，需要显式处理和降级

---

## Platform Channels (Pigeon)

| 通道 | 平台 | 方法 |
|---|---|---|
| `UsbHost` | Android | `requestPermission(vid,pid)`, `hotplug() → Stream`, `openDevice(fd)`, `bulkTransfer(...)`, `close()` |
| `WifiBinder` | Android | `bindToSsid(ssid,bssid?)`, `unbind()`, `state() → Stream`, `getCurrentSsid()`（包 `ConnectivityManager.requestNetwork` + `bindProcessToNetwork`）|
| `ForegroundService` | Android | `start(title,text)`, `updateNotification()`, `stop()`, `acquireLocks(wifi,multicast,wake)`, `releaseLocks()` |
| `IccPtp` | iOS 13.2+（iPhone + iPad 均适用） | `devices() → Stream`, `open(deviceId)`, `sendCommand(opcode,params,data?)`, `events() → Stream`, `close()` — Swift 层桥接 `ICDeviceBrowser` + `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`；iOS 18+ 处理 Wired Accessories 权限提示 |

---

## 并发模型

PTP 会话是严格串行的（一次一条命令）。每个 Transport 一个 `PtpOperationQueue`，单 worker 从 `PriorityQueue<PtpOperation>` 拉活。

优先级：`critical`（cancel/keepalive）> `high`（快门、写属性）> `normal`（读属性、事件轮询）> `low`（缩略图、LV 帧、传输分片）> `background`（大文件下载，每 chunk 后 yield）。

- Live View 循环自调度目标 ~30 Hz 在 `low` 优先级
- Keepalive 每 5s 抢占（发 `DeviceReady 0x90C8` 或 `GetEventEx 0x941C`）
- 取消：`CancelToken` 在 `GetPartialObjectEx` 每个 chunk 间检查；正在进行的拍摄用 `TerminateCapture 0x920C`
- **不要在后台切换时发 CloseSession**（Z 系列会掉 AP），只在用户主动断开时发

Isolate：协议层留在主 isolate（Socket 本身异步）。仅在低端 Android 需要 JPEG 解码时用 `compute()` 到 worker isolate，behind-drop 策略。

---

## 状态管理 (Riverpod 2)

顶层 providers（`app/lib/shared/providers/`）：
- `discoveryProvider` — Stream，bonsoir mDNS
- `transportProvider` — Notifier，管当前 Transport
- `sessionProvider` — AsyncNotifier，管 PtpSession 生命周期
- `deviceInfoProvider` — Future，一次性
- `cameraPropsProvider` — Stream，事件驱动更新
- `liveViewProvider` — autoDispose Stream + keepAlive 控制
- `storageProvider`, `objectListProvider(storageId)` (family)
- `transferQueueProvider`
- `galleryCacheProvider` — sqflite + 文件缓存
- `keepaliveProvider` — 监听 `AppLifecycleState`，后台化时**跳过 CloseSession**、切成 5s keepalive 心跳

---

## 分阶段交付（M1–M7）

| 里程碑 | 工期 | 内容 | 验收标准 |
|---|---|---|---|
| **M1 发现 + 连接** | 2 周 | bonsoir 扫 `_ptp._tcp` + `_nikon._tcp`；PtpIpTransport 双 Socket；InitCommand/InitEvent 握手；持久化 client GUID；`ChangeApplicationMode(1)` 进入控制模式 | UI 上能列出局域网内相机，选中后 5 秒内显示"已连接 Z6III"和序列号 |
| **M2 DeviceInfo + 读参数** | 1.5 周 | GetDeviceInfo → GetVendorPropCodes → GetDevicePropDesc（ISO / 光圈 / 快门 / WB / 曝光补偿 / 对焦模式） | 相机拨盘变动 ≤500 ms 内在 App 上反映（GetEventEx 轮询） |
| **M3 写参数 + 遥控快门** | 1.5 周 | SetDevicePropValue；InitiateCaptureRecInMedia；StartMovieRecInCard / EndMovieRec；DeviceReady 就绪轮询 | 拍照能触发；写属性后 round-trip 一致；录像启停正常 |
| **M4 Live View (Wi-Fi)** | 2 周 | StartLiveView；轮询 GetLiveViewImageEx(0x9428) @30 Hz；解 LV header；AF 框叠加；MfDrive 步进；tap-to-focus 走 ChangeAfArea + AfDrive | Pixel 6 / iPhone 13 上 Wi-Fi 稳定 ≥20 fps；AF 框跟随触点 |
| **M5 文件传输 (Wi-Fi)** | 2 周 | GetStorageIDs；分页 GetObjectHandles；GetThumb 网格；分片 GetPartialObjectEx(0x9431) 带续传和进度；Android FGS 活跃 | 40 MB RAW 不丢包；后台运行 10 分钟不断连；photo_manager 写系统相册成功 |
| **M6 USB 通道 (Android + iOS)** | 2.5 周 | PtpUsbTransport (quick_usb) on Android；IccPtpTransport on **iPhone + iPad**（同一 Swift 桥）；Wired Accessories 权限提示处理（iOS 18+）；热插拔 UI；两条通道并存时自动优先 USB。**四大功能（传输/遥控/参数/LV）全部在 USB 上再跑通一次**（备注：LV / 遥控 / 参数三项因走 `Transport` 抽象，M6a Android USB 完工时已自动覆盖；剩下的 USB 专属工作是传输队列 + iOS 侧的 IccTransport） | 三平台 USB 功能对齐 Wi-Fi 版；USB LV 帧率显著优于 Wi-Fi（Android 目标 ≥30 fps） |
| **M7 打磨** | 1.5 周 | 重连状态机；PTP 错误码本地化；机型 quirks 表；无障碍；i18n | 断连 30s 内自动重连；错误提示可读 |

**总工期估算：13 周**（M6 因加了 iPhone USB 路径 + Wired Accessories 权限处理，从 2 周增到 2.5 周；不含配对流程，v2 补齐）。

---

## 测试策略

**单元测试** (`packages/nikon_ptp/test/unit/`)
- 每种 PTP-IP 包类型 encode → bytes → decode 往返
- InitCommandRequest / InitEventRequest / StartData/Data/EndData 的 hex 黄金向量
- 覆盖 payload size = 0 / 1 / 512 / 65535 / >4 GB（触发 32→64-bit GetPartialObjectEx 路径）
- 用 `glados` 做长度前缀字段的 property test

**集成测试**：`tools/ptp_replay_server/` — 一个 Dart 二进制在 15740 端口回放录制好的字节 trace。
- 抓包方法：Windows 上用 Nikon 官方 NX Field 连一次相机，`tshark -Y "tcp.port==15740" -w cap.pcap` 抓包，写一个小 extractor 把 pcap 转成 `<opcode>.hex` fixture
- CI 里 NikonZClient 跑在 replay 上，无需真机

**Widget / golden 测试**：LiveView overlay 用固定 frame 做 golden。

**真机 smoke checklist**（每个固件跑一遍）：Wi-Fi + USB 都连；读所有属性；每个可写属性写一次；单张 + 连拍 5 张 + 10s 视频；下载 JPEG + RAW + MP4；LV 跑 15 分钟；后台 5 分钟后恢复。

---

## 风险登记

| # | 风险 | 缓解 |
|---|---|---|
| 1 | iOS ICC 对某些 vendor opcode 返回 `-21249` NotAuthorized；且 iOS 18+/26 有 `mediaFiles` 空返回 + `requestControlAuthorization()` 卡 `.notDetermined` 的已知回归 | 建立可用 opcode 白名单矩阵（每个 iOS 版本一份 canary）；不支持的 opcode 自动回退到 Wi-Fi；针对 iOS 18+ 回归实现"权限重试 + 断线重开会话"降级路径；密切跟踪 Apple Feedback 状态 |
| 2 | Live View 在低端 Android 掉帧 | 自适应 fps；behind-drop；JPEG 解码切 isolate；提供"降低 LV 质量"开关；USB 路径优先 |
| 3 | Android 返回蜂窝时相机 AP 断开 | WifiBinder 全程保持进程绑定；FGS 常驻；重连 FSM + 指数退避；**永远跳过 CloseSession**；5s keepalive |
| 4 | Android 13+ `NEARBY_WIFI_DEVICES` / 位置权限、iOS 18+ Wired Accessories 权限对话框吓退用户 | Android/iOS 两端都做 Onboarding 说明页 + 手动 IP 输入兜底；iOS 端配合 `NSCameraUsageDescription` 和 Wired Accessories 用途说明写清楚 |
| 5 | Nikon 固件回归（如 Z8 v3.0 改 0x9428 payload） | `constants/quirks.dart` 按 model+firmware 分支；连接时抓固件字符串；CI 里每个已测固件维护一份 canary golden trace |
| 6 | 相机 USB 模式设错（如 Nikon 私有 `[iPhone]` 模式），ICC 找不到设备 | Onboarding 明确要求"相机 USB 设为 MTP/PTP、关闭 Wi-Fi/BT/FTP"；连接失败时 UI 显示具体的相机菜单路径截图 |

---

## 关键文件

以下是需要**首先创建/最先编辑**的文件（按依赖顺序）：

1. `D:\rabbit\code\che\pubspec.yaml` — workspace 根，声明 melos + 子包
2. `D:\rabbit\code\che\packages\nikon_ptp\lib\src\constants\` — PTP-IP 包类型、标准 opcode、Nikon opcode、事件码常量
3. `D:\rabbit\code\che\packages\nikon_ptp\lib\src\codec\ptpip_codec.dart` — 包头 + payload 的 encode/decode
4. `D:\rabbit\code\che\packages\nikon_ptp\lib\src\transport\transport.dart` — Transport 接口
5. `D:\rabbit\code\che\packages\nikon_ptp\lib\src\session\ptp_session.dart` — 事务状态机 + operation queue
6. `D:\rabbit\code\che\packages\nikon_ptp\lib\src\client\nikon_z_client.dart` — 高层 Z 系列 API
7. `D:\rabbit\code\che\packages\nikon_ptp_flutter\lib\src\ptpip_transport.dart` — Wi-Fi 传输实现
8. `D:\rabbit\code\che\packages\nikon_ptp_flutter\lib\src\usb_transport.dart` — Android USB 传输实现
9. `D:\rabbit\code\che\packages\nikon_ptp_flutter\lib\src\icc_transport.dart` — iPad 传输实现
10. `D:\rabbit\code\che\app\lib\shared\providers\connection_providers.dart` — Riverpod providers
11. `D:\rabbit\code\che\app\android\app\src\main\kotlin\...\WifiBinder.kt` — Android Wi-Fi 绑定
12. `D:\rabbit\code\che\app\android\app\src\main\kotlin\...\CameraForegroundService.kt` — FGS
13. `D:\rabbit\code\che\app\ios\Runner\IccPtpPlugin.swift` — iOS ICC 桥（iPhone + iPad 共用）

---

## 验证方案（端到端）

**开发阶段**（每个 milestone 结束）：
1. `melos run test` — 全部单元 + golden 通过
2. 启动 `tools/ptp_replay_server` → App 连本地 replay → milestone 功能点全部走通
3. 真机跑 checklist（Wi-Fi 优先，M6 起加 USB）

**手动 E2E 验证脚本**（M5 完成时应能全过）：
```
1. 相机菜单 → 连接设置 → Wi-Fi → 打开
2. 手机连相机 AP（或同网段 STA）
3. 打开 App，看到相机出现在发现列表 → 点连接
4. App 显示型号 + 序列号 + 存储卡容量
5. 调 ISO 3200 → 相机屏立即变化
6. 拍一张 → 事件通知到达 → App 显示新缩略图
7. 点缩略图下载 → 进度条正常 → 打开系统相册确认文件在
8. 开 Live View → 帧率显示 ≥20fps → tap-to-focus 生效
9. 后台 App 3 分钟 → 恢复 → 会话仍连通
10. 主动断开 → CloseSession 发出 → 相机可下次重连
```

**CI 门槛**：
- 单元 + golden 100% 通过
- Replay 集成测 100% 通过
- 静态分析 `flutter analyze` 零 warning
- 包依赖锁定，`melos publish --dry-run` 通过（为 `nikon_ptp` 包未来单独发布留门）

---

## Progress 快照（更新于 2026-08-18，M1 mDNS 收尾完成 + M6b iOS 通道完成 + GitHub Actions 免签 IPA 流水线）

| 里程碑 | 状态 | 已完成 | 未完成 |
|---|---|---|---|
| **M0 基础脚手架** | ✅ 完成 | Workspace + melos + analysis_options；`nikon_ptp` 常量层 + 数据模型 + codec（PTP-IP + PTP-USB + PTP 数据结构）+ Transport 接口 + `PtpSession`（含优先级 OperationQueue）+ `NikonZClient` 高层 API；64 个单元测试全绿 | — |
| **M1 发现 + Wi-Fi 连接** | ✅ 完成 | `PtpIpTransport` 双 Socket 完整握手（InitCommand/InitEvent Ack）+ 持久化 client GUID（`ClientGuidStore` via shared_preferences）+ `ChangeApplicationMode(1)` 进入控制模式（且 AccessDenied 优雅降级）；`ConnectingScreen` 真实握手，日志流可视化；**mDNS 发现完整化**：`WifiCameraDiscovery`（`packages/nikon_ptp_flutter/lib/src/wifi_discovery.dart`）用 bonsoir 订阅 `_ptp._tcp` + `_nikon._tcp`（可配置），push-based（无轮询）— `serviceFound → resolve → serviceResolved` 三段状态机，按 service name 去重，`serviceLost` 自动摘除；`wifiCameraDiscoveryProvider` 在 Android/iOS/macOS 启用（Windows/Linux 留 empty，未验证）→ merge 进 `discoveryProvider`；`iOS Info.plist` 加 `NSLocalNetworkUsageDescription` + `NSBonjourServices=[_ptp._tcp, _nikon._tcp]`（iOS 14+ 强制要求）；Android manifest 加 `INTERNET/ACCESS_NETWORK_STATE/ACCESS_WIFI_STATE/CHANGE_WIFI_MULTICAST_STATE/NEARBY_WIFI_DEVICES(neverForLocation)`；**15 个 `WifiCameraDiscovery` 单测**覆盖初始空快照 / start-stop 生命周期 / found→resolve→resolved 转换 / host 缺失静默 drop / duplicate resolve in-place update / lost 未知 name 不 spam / resolve 失败不炸流 / event-stream 错误透传 / 多服务类型 merge | Wi-Fi 侧真机验证（相机→AP→App 端到端） |
| **M2 DeviceInfo + 读参数** | ✅ 完成 | `getDeviceInfo` / `getStorageIds` / `getStorageInfo` / `getObjectHandles` / `getObjectInfo` / `getPropertyDesc` / `pollEvents` 全部在 `NikonZClient` 里实装；`connect()` 自动调 GetDeviceInfo；`PropFormatter` 覆盖 ISO/快门/光圈/EV/WB/AF/曝光模式/驱动/电量/焦距/闪光/测光（21 个单元测试）；`cameraPropertiesProvider` 事件驱动 + 500ms 兜底轮询（9 个 provider 测试）；参数抽屉屏 + LiveView 顶部 ExposureBar 全部接真值，只读属性显示 🔒 图标 | 参数写入 UI（属于 M3） |
| **M3 写参数 + 遥控快门** | ✅ 完成 | `setProperty` / `capture` / `startMovieRecording` / `stopMovieRecording` / `_waitDeviceReady` 已实装（client 层）；`CameraCommands` 门面统一包装错误 → `CameraControlFailure` 带中文 hint；`cameraCommandsProvider` 从 activeConnectionProvider 拿 client；参数抽屉行 tap 弹选值 sheet（EnumForm 显示可选枚举高亮当前值，RangeForm 显示带 step 的 slider），非可写属性显示 🔒 图标不响应 tap；LiveView 快门键 tap → `capture()` + haptic + SnackBar 反馈，in-flight 期间灰化；视频模式 tap → `startMovieRecording/stopMovieRecording` + HUD 秒级 Timer.periodic，录像期间锁定模式切换以避免竞态；11 个 `CameraCommands` 单元测试 | 静默失败重试策略、连拍/自定义存储卡目标（走 `capture(storageId:)`）暂未做 |
| **M4 Live View (Wi-Fi + USB)** | ✅ 主线完成 | `startLiveView` / `stopLiveView` / `getLiveViewFrame` API 就绪；`LiveViewFrameCodec.decode` 按 JPEG SOI 拆头 + JPEG，尽力解析图像宽高 + AF/焦点框（10 个单测）；`NikonZClient.getLiveViewFrameDecoded` + `tapToFocus`（7 个单测，含 AF-out-of-focus 静默降级）；App 层 `runLiveView` 自调度 30 Hz 循环 + 滚窗 FPS 计算 + 启动/取消状态机（6 个单测）；`liveViewProvider` autoDispose Stream；LV 屏 `LvScene` 用 `Image.memory(gaplessPlayback: true)` 渲染真实 JPEG，warmup/error 态回退暖色渐变；LV 屏 tap → `tapToFocus`，屏幕坐标按帧宽高缩放；HUD fps 显示实测滚窗值。**整条管线走 `NikonZClient` → `PtpSession` → `Transport` 抽象，Wi-Fi 和 USB 共用同一份代码路径，无 channel 分支** —— M6a 已经让 `UsbTransport` 真机走通，所以插 USB 打开 LV 屏就直接工作；原 M6 里"USB 上再跑通一次 LV"这一项因此不需要单独实现 | 真机 fps 实测（Wi-Fi 目标 ≥20 fps，USB 目标 ≥30 fps）；LV header 更多字段（histogram/exposure）；MfDrive 微调步进；LV 帧 JPEG 解码切 isolate 的低端设备优化；`LiveViewStateChanged=0xC10C` 事件订阅重连（当前完全靠 30 Hz 主动拉取） |
| **M5 文件传输 (Wi-Fi)** | 🔴 未开始 | `downloadObject` 分片实装（GetPartialObjectEx 64-bit + Cancel Token） | Gallery 屏对接真实 handle 列表 + GetThumb；Transfer 屏对接 downloadObject 流 + photo_manager 写系统相册；Android FGS 未做 |
| **M6a USB (Android)** | ✅ 完成 | `PtpUsbCodec`（USB Still Image Class 1.0 container）+ `UsbTransport`（quick_usb bulk-IN/OUT，cmd/data/response 三阶段）+ `UsbCameraDiscovery`（poll + Nikon VID/PID 表）+ Android manifest `USB_DEVICE_ATTACHED` intent-filter + `device_filter.xml`（Z 系列全型号）+ **quick_usb fork**（`packages/quick_usb_patched`，绕开 pub 版 `compileSdkVersion 30` 但引用 API 31 符号的编译不能问题）；**transport 硬化**：fork 里把 bulk IN/OUT + 新增的 clearHalt 全部挪到 `Executors.newSingleThreadExecutor("quick_usb-io")` 后台线程，结果 `Handler(Looper.getMainLooper())` 切回主线程（相机 30s 不回不再 ANR）；`UsbTransport.open()` claim 之后对 bulk-IN/OUT 各做一次 best-effort `CLEAR_FEATURE(ENDPOINT_HALT)`，兜底前一次崩溃留下的端点 halt；真机 STF AL00 上 Nikon Z 系列已成功握手 + 拍摄/写属性/录像跑通 | USB interrupt 端点（异步事件推送）—— 当前靠 `pollEvents` 兜底 |
| **M6b USB (iOS)** | ✅ 完成 | Pigeon schema `icc_ptp.dart`（`IccCameraInfo` / `PtpCommand` / `PtpCommandResult` + Host/Flutter Api）；iOS 插件 `packages/nikon_ptp_flutter/ios/`（`nikon_ptp_flutter.podspec` 声明 `ImageCaptureCore` framework + platform `:ios, '15.2'`）+ `IccPtpPlugin.swift`（HostApi 三方法接到 coordinator；**拦截 OpenSession(0x1002) / CloseSession(0x1003) opcode 直接合成 `0x2001`**，ICA 自己管会话，别让 PtpSession 双开）+ `IccDeviceCoordinator.swift`（持有 `ICDeviceBrowser` 过滤 camera+local；`didAdd/didRemove` 推 `onDeviceAdded/Removed`；`openSession → requestOpenSession + ICDeviceDelegate.didOpenSessionWithError`；`sendPtpCommand` 构造 12 字节 PIMA 15740 命令块（`[len\|type=0x0001\|opcode\|txId\|params...]`）→ `requestSendPTPCommand(_:outData:sendCommandDelegate:didSendCommand:contextInfo:)` 走 selector 回调 → 解析 response 块 → PtpResponse；`ICCameraDeviceDelegate.didReceivePTPEvent` 解析事件块 → `onPtpEvent`）+ `IccPtpChannel.dart` singleton demux FlutterApi 分发到 discovery 和 transport；`IccTransport.dart` 走通 `open → openSession`、`sendTransaction → sendCommand + tx id 计数`、`close → closeSession`、`streamTransaction` yield 一次；App 层 `iccCameraDiscoveryProvider`（iOS 平台开启）+ merge 进 `discoveryProvider`；`connection_controller` 加 `connectIcc(iccDeviceId:)`；`connecting_screen` 分 usb/icc 路由；`DiscoveredCamera` 加 `iccDeviceId` 字段；`onboarding_screen.dart` 里 iOS "USB 有线" 按钮走 `IccCameraDiscovery` 而非 quick_usb；`Info.plist` 加 `NSCameraUsageDescription` + `CFBundleName` 改为 "Nikon Z Control"（去掉下划线,Apple appIdName 校验限制）；`Podfile` platform `:ios, '15.2'`；Runner project `IPHONEOS_DEPLOYMENT_TARGET = 15.2`；**热插拔完整链路**：Swift 端 `ICDeviceBrowserDelegate.deviceBrowser(_:didRemove:...)` + `ICDeviceDelegate.didRemove(_:)` 双写覆盖（iOS SDK 版本差异,哪个先 fire 不一定）→ `onSessionEnded(deviceId, "unplug")` → Dart `IccTransport._onSessionEnded` → `state = failed` → Dart `transportDisconnectWatcherProvider` 挂 `activeConnectionProvider` 的 stateChanges → 清空 activeConnection → LV 屏 `ref.listen` 弹 "相机已断开" SnackBar + `context.go(discovery)`；GitHub Actions macOS runner 免签 IPA 自动打包（`.github/workflows/ios-build.yml`）；iPhone 17 (iOS 26) + Nikon Z 系列真机验证：握手 / 参数读写 / LiveView / 拍照 / ISO 拨轮事件同步 / 拔线自动返回列表 全部跑通；12 个 `IccTransport` 单测（`packages/nikon_ptp_flutter/test/icc_transport_test.dart`）覆盖 open / sendTransaction / txId 单调 / dataOut 转发 / PTP event → CameraEvent / 热插拔 / close 幂等 | iOS 18+ Wired Accessories 权限被拒的自定义提示引导（当前只能靠系统对话框）；Wi-Fi 侧 iOS 端 mDNS 发现（属于 M1 收尾）；相机侧按快门后 App 自动加入下载队列（属于 M5 收尾） |
| **M7 打磨** | 🔴 未开始 | AccessDenied 加了排障文案 | 重连状态机、i18n、无障碍、机型 quirks 完整表 |

### 意外命中的坑与修法（不在原计划里）

| 症状 | 根因 | 修法 |
|---|---|---|
| pub 上 `quick_usb` 只到 0.4.0，且 Android 源码里引用 `Build.VERSION_CODES.S` / `PendingIntent.FLAG_MUTABLE` 但自己的 build.gradle 只声明 `compileSdkVersion 30` | 常量在 API 31 才有；30 编译不过；Flutter Gradle 的 compileSdk 传递不作用于 plugin 子项目自己声明的 android {} 块 | Fork 到 `packages/quick_usb_patched`：Kotlin 换成数字字面量（31 / 0x02000000），build.gradle 升到 34；根 pubspec 走 `dependency_overrides: quick_usb: path: ...` |
| Kotlin 增量编译报 `IllegalArgumentException: this and base files have different roots` | pub cache 在 `C:\`、项目在 `D:\`，Kotlin 增量 cache 跨盘符算不出相对路径 | `app/android/gradle.properties` 里加 `kotlin.incremental=false` |
| `BytesBuilder(copy: false)` + 复用 `_scratch ByteData` 导致所有多字节写被后一次写覆盖 | `asUint8List` 是 view，`copy: false` 不 copy，view 内容随下一次 write 变化 | 改回默认 `BytesBuilder()`（`copy: true`）；43 个 codec 单测过 |
| `PacketFramer` 用 non-broadcast StreamController 导致 PtpIpTransport 尝试第二次 listen 时 StateError | 单订阅流不能多 listener | 改成 `StreamController.broadcast` |
| `ChangeApplicationMode(1)` 在某些 USB 场景返回 AccessDenied (0x200F) | 相机可能已在正确模式或纯 MTP 模式不允许升级 | `NikonZClient.connect()` 白名单里加 AccessDenied/OperationNotSupported/DeviceBusy 等码为"非致命"，跳过并置 `changeApplicationModeSkipped` flag，让读路径继续 |
| 连接失败时 UI 只显示裸 code `0x200F` | 错误信息缺少 opcode 上下文和用户可读的排障建议 | `ConnectionController` 加 `_opcodeName()` + `_hintForResponse()` 表 |
| M3 上线后首次 USB 连接 30s 无响应，Android 弹 ANR，控制台报 `PlatformException(unknown, bulkTransferOut error)` | `quick_usb 0.4.0` 上游把 `UsbDeviceConnection.bulkTransfer` 直接跑在 `onMethodCall`（Android UI 主线程）；相机在超时窗口内不回 → 整个 UI 线程冻住 → ANR | fork 的 `QuickUsbPlugin.kt` 加了 `ioExecutor = Executors.newSingleThreadExecutor("quick_usb-io")`（单线程是故意的：同一 `UsbDeviceConnection` 上并发不安全），bulk IN/OUT 全部 `ioExecutor.execute { ... }`，结果 `mainHandler.post { result.success/error(...) }` 切回主线程；`onDetachedFromEngine` 里 `shutdownNow()` 清理 |
| 前一次 session 崩溃或热重载留下 bulk 端点 halt，新一次连接首个 bulkTransferOut 卡到超时 | PTP-USB 三阶段协议里，任何一阶段异常终止都可能把 bulk 端点留在 halted 状态；`claimInterface` 不清 halt | quick_usb fork 里新增 `clearHalt(endpoint)`：Kotlin 走 `controlTransfer(0x02, 0x01, 0, endpointAddress, ...)` = CLEAR_FEATURE(ENDPOINT_HALT)；Dart 抽象层默认 no-op（桌面 libusb 端不需要），Android 实现走 method channel；`UsbTransport.open()` claim 之后对 bulk-IN/OUT 各调一次 best-effort（`try/on Object` 兜住，非致命） |
| 参数抽屉行 tap 空转 / 快门键 tap 空转（M2 时状态） | UI 层缺少统一的命令门面，散在 widget 里直接调 `client.xxx` 会重复错误映射逻辑 | 加 `CameraCommands`（`app/lib/shared/providers/camera_control_provider.dart`）：`capture`/`setProperty`/`start/stopMovieRecording` 四个方法统一 `try/catch → CameraControlFailure.fromError`，`CameraControlFailure.userMessage` 直接进 SnackBar；`_hintForResponse` 表在这里集中维护（15 个常见 code），未来的 Gallery/Transfer 屏也可以复用 |
| M6b：`melos bootstrap` 在 CI macOS runner 上失败 "Your current directory does not appear to be within a Melos workspace" | melos 6.x 起要求配置放根 `pubspec.yaml` 的 `melos:` key，我们的独立 `melos.yaml` 已被淘汰；而且项目本身用 Dart 3.6+ **原生 pub workspace**，根本不需要 melos | GitHub Actions workflow (`.github/workflows/ios-build.yml`) 里砍掉 `melos bootstrap` 一步，直接 `flutter pub get`（原生 workspace 感知） |
| M6b：iSideload 装 IPA 报 `Developer error 35: An invalid value 'nikon_z_control' was provided for the parameter 'appIdName'` | Apple Developer Portal 注册 App ID 时 `appIdName` **只允许字母/数字/空格**，我们 `Info.plist` 里的 `CFBundleName = nikon_z_control` 带下划线 | 改 `CFBundleName = "Nikon Z Control"`（`CFBundleDisplayName` 早已是空格版本，只是没同步到 CFBundleName） |
| M6b Phase B：Swift 报 `'ICDeviceTypeMask' is only available in iOS 15.2 or newer` + `'persistentIDString' is unavailable in iOS` | plan 里判断的"iOS 13.2+ 可用"是**引入 API 的版本**，但 `ICDeviceTypeMask` / `browsedDeviceTypeMask` 这些**过滤器枚举**到 iOS 15.2 才 export；`ICDevice.persistentIDString` 全 iOS 版本都不存在(macOS-only)，同理 `serialNumberString` / `isRemote` | Podfile / Runner.xcodeproj / `nikon_ptp_flutter.podspec` 三处 iOS deployment target 全部 `13.2 → 15.2`（iPhone 17 是 iOS 26，代价为零）；`ICDevice` id 改用 `ObjectIdentifier(device).hashValue`（浏览器生命周期内稳定）；`serial` / `isRemote` 在 iOS 侧硬编码 nil/false，等 PTP `GetDeviceInfo` 之后拼真值 |
| M6b Phase C：Swift 报 `Type 'IccDeviceCoordinator' does not conform to protocol 'ICCameraDeviceDelegate'` | Apple 把 `ICCameraDeviceDelegate` 的一堆 `@objc optional` 方法在 Swift 侧当 required 处理（Xcode Fix-It 会插全套）；有 10 个方法需要实现 | 全都实现为 no-op（`didAdd/didRemove/didRenameItems/didReceiveThumbnail/didReceiveMetadata/cameraDeviceDidChangeCapability/deviceDidBecomeReadyWithCompleteContentCatalog/cameraDeviceDidRemoveAccessRestriction/cameraDeviceDidEnableAccessRestriction/didEncounterError`），只在 `didReceivePTPEvent` 里真做事；同时 `import CoreGraphics` 因 `CGImage` 类型 |
| M6b Phase C：Swift 又报 `'deviceDidBecomeReadyWithCompleteContentCatalog' has been renamed to 'deviceDidBecomeReady(withCompleteContentCatalog:)'` | Swift 桥的 API 命名早就迁移了，Obj-C 方法头一模一样,但 Swift interop 强制新名字 | 改名 |
| M6b Phase F：拔 USB 线后 App 卡在 Live View 屏,不返回相机列表 | iOS SDK 版本差异,`ICDeviceBrowserDelegate.deviceBrowser(_:didRemove:...)` 和 `ICDeviceDelegate.didRemove(_:)` 哪个先 fire 不一定,只写 browser 端会漏；App 层也没监听 transport 状态变化 | Swift 端两个 didRemove 都写(idempotent);Dart 端新加 `transportDisconnectWatcherProvider` 挂 `activeConnectionProvider` 的 stateChanges,transport → failed/closed 时清空 activeConnection;LV 屏 `ref.listen` 到 activeConnection 变 null → SnackBar + `context.go(discovery)` |
| M6b Phase A observability：iOS ICA 连接每次都要等 3–5 分钟（不只首次），且 `ConnectingScreen` 是彻底黑盒——`IccDeviceCoordinator.swift` 一行日志都没有，`_api.openSession(deviceId)` 也没超时 | 完全无从判断卡在哪一步：可能是 `requestOpenSession → didOpenSessionWithError` 之间 Apple ICA 在扫描相机媒体目录（`ICCameraDevice.contentCatalogPercentCompleted`），可能是权限 / 首次配对握手，也可能是后续 PTP 命令。缺乏观测手段无法进一步定位 | **Phase A**（可观测性 + UX 兜底）落地：Swift 加 `os.Logger`（subsystem `com.che.nikon_ptp_flutter` / category `icc`）到每个 phase transition；KVO 监听 `contentCatalogPercentCompleted` 把百分比 push 到 Flutter；新增 120s watchdog（`DispatchWorkItem`）超时时触发 `onSessionEnded(reason:'timeout')` + fail pending completion；新增 Pigeon FlutterApi 事件 `onSessionOpenProgress(deviceId, phase, percent, elapsedMs)`（phase ∈ `openSession/catalog/ready/timeout`）；`IccTransport.open()` 加 `openTimeout=120s`；`IccTransport.openProgress` 广播 stream；`ConnectionController._runHandshake` 由 async* 改成 StreamController，让 progress 事件能在 `await transport.open` 期间插入；per-channel 的 timeout 错误文案（icc → `"ICA 会话超时（120s）— 尝试重新插拔 USB-C 线；如仍不行请在 iOS 设置 → 隐私与安全 → 有线配件里检查授权"`）；`_ConnLog` 变 stateful，active 行显示实时递增秒数，卡 >10s 显示 channel-specific 提示文案。**Phase B（尝试绕过 ICA catalog 扫描）+ Phase C（真正的 abort 路径）**gated on 拿到一次真机 os_log 后再决定 |
| M6b Phase A 补丁：连接成功后 500ms 自动跳 LV，用户没机会复制"连接日志"，Phase A 加的诊断能力等于白做 | `_handleReady` 一律 `context.go(liveView)`，不管连接花了多久 | `_handleReady` 只 populate `activeConnection`，导航改由新增的"进入实时取景"主按钮触发；`_ActionButtons` 加 `succeeded` 分支（`[返回列表]` + `[进入实时取景]`）；AppBar 标题成功时变 `已连接 · <name>`；日志面板的"📋 复制日志"按钮全程都在 |
| M6b Phase A 补丁 2：Windows/Linux 用户没有 macOS Console.app，Swift 侧的 `os.Logger` 数据完全够不到 —— Phase A 只给 macOS 用户看得清 | Swift 日志只走 `os_log`，App 里看不到 | 新增 Pigeon FlutterApi 事件 `onDiagnosticLog(tag, message, elapsedMs)`；`IccDeviceCoordinator` 里把每个 `Self.log.info/.error(...)` 换成 `log(_ tag:_ message:error:elapsedMs:)` 帮助方法，同时走 os_log AND flutterApi.onDiagnosticLog；`IccPtpChannel` 加 `setDiagnosticLogListener` demux；`IccTransport` 加 `diagnosticLogs` 广播 stream + `IccDiagnosticLog` 公共模型；`ConnectionController` 订阅并转成 `[SWIFT]` tag 的 info-level ConnectionLog；`_ConnLog` 加 260px 上限 + `SingleChildScrollView` + 尾部自动滚动；顶部行加"📋 复制日志"按钮，全程可见，复制内容含 device/channel/platform/OS 抬头；`NikonZClient.connect(onPhase:)` 新增可选相位回调，`ConnectionController` 把之前一个 blob 的 `CTRL · OpenSession + GetDeviceInfo…` 拆成 4 步单独计时行（PtpSession.open / GetDeviceInfo / ChangeApplicationMode / DeviceReady） |
| M6b Phase B（进行中）：真机日志确认根因 —— **不是 ICA session 打开慢（1ms 秒开），也不是 catalog 扫描本身慢（0→9% 只用了 200ms），而是 Apple ICA 在 `didOpenSessionWithError` 触发后、放行用户第一条 `requestSendPTPCommand` 之前，内部要跑一遍 storage/object enumeration**。Z 30 + 有内容的 SD 卡上 = 103 秒；拔掉 SD 卡后 = 秒连（用户实测）。后续 PTP 命令都很快（ChangeApplicationMode 161ms、DeviceReady 43ms） | Apple ICA 的 delegate 设计假设你会等 `deviceDidBecomeReady(withCompleteContentCatalog:)`，你的 `requestSendPTPCommand` 被 ICA 排在它的内部枚举 PTP 序列后面 | 尝试 `respondsToSelector:` 技巧：override `IccDeviceCoordinator.responds(to:)` 对 7 个媒体目录相关的 delegate selector（`cameraDevice:didAddItems:` / `didRemoveItems:` / `didReceiveThumbnail:forItem:error:` / `didReceiveMetadata:forItem:error:` / `didRenameItems:` / `cameraDeviceDidChangeCapability:` / `deviceDidBecomeReadyWithCompleteContentCatalog:`）返回 `false`。理由：ObjC 标准 delegate 调用协议是先 `respondsToSelector:` 再 `objc_msgSend`；如果 ICA 遵守这个约定，看到我们不响应这些回调，可能就不会去做喂给它们的枚举。Swift bridge 强制这些方法必须实现，所以 no-op stub 保留，但运行时 override 让 ObjC 侧看不到。**未公开行为，等真机测试验证** —— 有效则跟拔卡一样秒连；无效则回退到 eager pre-open 方案 |

### 下一步优先级建议

1. **M5 Gallery/Transfer 对接**（首屏可用性最大）：Gallery 用 `getObjectHandles + getThumb`；Transfer 用 `downloadObject` + `photo_manager`；顺手在 PtpSession.events 里挂 ObjectAdded (0x4002) 监听,拍照自动进队列
2. **M4 真机验证**：拿实测 fps + 确认 LV header 偏移量在当前固件下正确
3. **M1 Wi-Fi 侧真机验证**：mDNS 代码路径已完整，需要真机端到端跑一遍（相机开 AP → App 端 bonsoir 发现 → tap 卡片 → PtpIpTransport 握手 → 参数读写 / LV / 拍照）
4. **M7 重连状态机**：断网/挂起/后台切换的 keepalive + 自动重连（现在 unplug 已经有基础,能扩展到 Wi-Fi 断线场景）
