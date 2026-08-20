# iOS USB 相机连接调优 —— 全过程复盘

> 时间：2026-08-19 → 2026-08-20
> 目标机型：iPhone 17 (iOS 26.5.1) + Nikon Z 30 + 满 SD 卡
> 涉及代码：`packages/nikon_ptp_flutter/ios/Classes/*` + `packages/nikon_ptp_flutter/lib/src/*` + `app/lib/features/connection/*`

---

## 1. 问题定义

用户反馈：**iOS 通过 USB-C 连接 Nikon Z 相机非常慢，等 3–5 分钟才进 Live View，有时甚至连不上**。M6b Phase F 之前只做了功能贯通，没做过速度基准。

**初始诊断能力：几乎为零** —— Swift 侧 `IccDeviceCoordinator.swift` 一行日志都没有；Dart 侧 `_api.openSession(deviceId)` 没有超时；UI 只有一个转圈的 spinner。**3 分钟里到底卡在哪、谁在等什么，完全是黑盒。**

## 2. 目标 & 参照系

参照物：**影控台**（App Store id 6768196167，由前 Nikon NPS 员工"视觉矿洞"开发的第三方 App）和 **Cascable Studio**（App Store，商业 SDK CascableCore，由英国 Daniel Kennett 开发）。

**在同款硬件（iPhone 17 + Z 30 + 满卡 + 冷启动）上的对比数据：**

| App | 冷启动连接耗时 |
|---|---|
| Cascable Studio | **5 秒** |
| 影控台 | **秒连** |
| 我们（Phase A 前） | **78-103 秒** |
| 我们（Phase B v5 后，本文档止步的状态） | **30-190 秒**（方差巨大） |

## 3. 探索路径（按时间顺序）

### 3.1 Phase A：可观测性 + UX 兜底

**Commit `d2dbb24`, `f6a1194`, `ab73fc1`**

从"完全黑盒"到"每一步都能定位"：

- **Swift `os.Logger`** —— subsystem `com.che.nikon_ptp_flutter` / category `icc`；后来通过新增的 Pigeon FlutterApi 事件 `onDiagnosticLog` 镜像到 Dart 侧（因为用户在 Windows，看不到 macOS Console.app）
- **KVO 监听 `ICCameraDevice.contentCatalogPercentCompleted`** —— 把 catalog 扫描百分比 push 到 UI
- **120s watchdog** —— 通过 `DispatchWorkItem` 防止 pending completion 无限等待
- **In-app 复制日志按钮** —— `ConnectingScreen` 右上角 📋，全程可见，格式化后复制到剪贴板
- **`_ConnLog` 变 stateful** —— active row 实时递增秒数；卡 >10s 显示 channel-specific 提示
- **per-PTP-step 计时** —— `NikonZClient.connect` 新增 `onPhase` 回调；把之前一个 blob 的 `OpenSession + GetDeviceInfo…` 拆成 4 步单独计时（PtpSession.open / GetDeviceInfo / ChangeApplicationMode / DeviceReady）
- **成功后不再自动跳 LV** —— 加"进入实时取景"按钮，让用户有机会复制日志
- **诊断日志 buffer** —— `IccPtpChannel` 保留最近 200 条日志，新 listener attach 时回放，防止早期 log 丢失

**收益：** 后续所有决策都依赖这里的数据。

### 3.2 Phase B v1：`respondsToSelector:` 骗过 ICA

**Commit `b021d4d`**

**假设：** Apple ICA 在 delegate 方法调用前会先问 `[delegate respondsToSelector:@selector(方法名)]`。如果我们对媒体目录相关的 7 个 delegate 方法返回 `NO`，ICA 可能不去做喂给它们的枚举。

**实现：** override `IccDeviceCoordinator.responds(to:)` 隐藏这 7 个 selector：
- `cameraDevice:didAddItems:` / `didRemoveItems:` / `didReceiveThumbnail:forItem:error:` / `didReceiveMetadata:forItem:error:` / `didRenameItems:` / `cameraDeviceDidChangeCapability:` / `deviceDidBecomeReadyWithCompleteContentCatalog:`

**结果：** **部分生效** —— `catalog.progress` 全程停在 0%（Phase 2 per-file catalog 枚举被禁掉了），但 warmup 还是 78s（Phase 1 storage handle 枚举还在跑）。

**结论：** 找到了两阶段结构；第二阶段可跳，第一阶段跳不掉。

### 3.3 Phase B v2：Eager Pre-Open + Warmup PTP

**Commit `4c355dc`**

**假设：** 78s 的税跳不掉，但可以**挪到用户看不到的地方交**。用户从看到相机在列表到点击有几秒到几十秒的空档。

**实现：**
- 新增 Pigeon HostApi `setEagerPreOpen(bool)`，Dart 侧在 `IccCameraDiscovery.watch()` onListen / onCancel 时切换
- Swift 收到 enabled=true 后，`deviceBrowser(_:didAdd:)` 时立即调 `requestOpenSession()` + 发一条 warmup `GetDeviceInfo (tx=1)`
- `pendingOpenCompletion: Single?` → `pendingOpenCompletions: List` 重构，让用户点击时的 openSession call 能 attach 到进行中的 eager
- `warmupCompletedDeviceIds: Set<String>` fast-path gate

**结果：** 逻辑上正确 —— 如果用户在插上相机后 >78s 才点，连接秒开；实际情况用户几乎是立刻点击，效果甚微（省 3-5 秒）。

### 3.4 Phase B v3：`requestControlAuthorization`

**Commit `1882814`, `5dc4425` (修实例方法), `edd4f5f` (加可观测性)**

**假设：** iOS 14+ 的 `ICDeviceBrowser` 有两个正交授权门 —— `requestContentsAuthorization`（触发存储枚举）和 `requestControlAuthorization`（只要控制权限）。**只调 control 版本、绝不调 contents 版本**，ICA 可能不做枚举。

**实现：**
- `IccDeviceCoordinator.init()` + `setEagerPreOpen(true)` 里都调 `self.browser.requestControlAuthorization {}`
- 从不调 `requestContentsAuthorization`
- 记录 auth 状态到日志

**验证：** 实测 `auth.control.status = ICAuthorizationStatusAuthorized` (status=3)，**授权确认成功**。

**结果：** **对速度没有可测量的影响。** 三次真机测试：
- Test 1 (冷启动): 78s
- Test 2 (未重启): 46s  
- Test 3 (未重启): 46s

**关键 side-finding：** 冷启动 78s、随后 46s，差 32s 稳定复现 —— **iOS 内部对 (相机型号, 序列号) 缓存了 storage layout**，重启即丢，是我们控制不了的层面。

### 3.5 Phase B v4：KVC 私有属性

**Commit `a32faae`**

**假设（来源于 LeoNatan 的 iOS runtime header dump）：** `ICCameraDevice` 有私有属性 `basicMediaModel` / `preheatMetadata` / `ptpEventForwarding`。Cascable 的 SDK 文档把能力分成 `RemoteShooting` vs `FilesystemAccess`，字面对应 `basicMediaModel` 语义。Kennett 说过 "we figured out what the problem was and were able to find the right person at Apple to help"，可能就是用这些私有属性。

**实现：** `applyControlModeTuning(on: camera)` 在 `requestOpenSession()` 前用 `setValue:forKey:` 设置：
- `preheatMetadata = NO`
- `basicMediaModel = YES`
- `ptpEventForwarding = YES`

每个 setter 前用 `responds(to:)` guard，缺失自动降级。

**实测结果（iOS 26 上的 property 存在性）：**
- `preheatMetadata setter unavailable on this iOS` —— iOS 26 移除了
- `basicMediaModel=YES applied` —— 存在且成功设置
- `ptpEventForwarding=YES applied` —— 存在且成功设置

**速度结果：极不稳定**

| 运行 | warmup elapsedMs |
|---|---|
| 冷启动第一次 | 78s |
| 冷启动第二次（不同物理会话） | **30s** ⭐ 一度让人以为有效 |
| 冷启动第三次 | **191s** ❗ 比 baseline 还慢 2.4 倍 |

**结论：** `basicMediaModel=YES` 效果**噪音级别**。可能在 iOS 26 里语义已变，甚至可能设 YES 让 ICA 做更多工作。

### 3.6 Phase B v5：私有 `requestOpenSessionWithOptions:` 方法

**Commit `bffa66c`, `e305e5b`**

**假设：** 与其后设 property 再调 `requestOpenSession()`（可能 ICA 已经开始决定要枚举了），不如**直接调 LeoNatan dump 里的私有 open 方法**，把选项作为 options 字典**一次性传给 open**，让 ICA 在第一个内部 state 就知道要"控制模式"。

**实现：** 优先调 `requestOpenSessionWithOptions:` via `perform(selector:with:)`，传字典（同时包含 property 名和 `ICCameraDeviceXxx` 前缀变体，覆盖多种可能的 key 命名）。

**结果：**
```
openSession.requestOpenSession issued (options API unavailable, fallback)
```
→ **iOS 26 也移除了这个私有方法。** 完全 fallback 到 vanilla 路径，warmup **191s**。这条路死了。

## 4. 稳定收益汇总

尽管速度攻坚失败，Phase A/B v1-v3 的工程改进是**扎实的、可保留的**：

| 收益 | 措施 | 来源 commit |
|---|---|---|
| **可观测性 100%** | os.Logger + Pigeon 镜像到 Dart + iccBuildTag 版本追踪 | d2dbb24, f6a1194, e0bd84b |
| **UX 兜底** | 复制日志按钮 / 实时秒数 / channel-specific 超时文案 / 成功不自动跳 | f6a1194, ab73fc1 |
| **控制授权正确性** | 显式调 `requestControlAuthorization`, 从不调 contents 版本 | 1882814 |
| **诊断日志无丢失** | 200 条 ring buffer + listener attach 时回放 | e0bd84b |
| **eager pre-open** | Discovery 挂起时后台 warm session | 4c355dc |
| **Phase 2 catalog 扫描已禁** | `respondsToSelector:` 隐藏 7 个媒体 delegate 方法 | b021d4d |
| **per-PTP-step 计时** | 拆开 `client.connect()` 的 4 步 | f6a1194 |
| **120s watchdog + timeout 分级** | Dart 侧 openTimeout + Swift 侧 watchdog | d2dbb24 |

## 5. 关键根因（Apple 官方，无法绕开）

**Apple Radar FB7593726**（[openradar 链接](http://www.openradar.appspot.com/FB7593726)）明确记录：

> iOS 上 `requestSendPTPCommand` 会返回 `-21249 ICReturnPTPNotAuthorizedToSendCommand`，直到 `deviceDidBecomeReadyWithCompleteContentCatalog:` 触发 —— 也就是**等 ICA 内部完成完整存储枚举**。

**这就是 78s 税的根源。**空卡秒开的原因是"完整存储枚举"瞬间完成（没东西可枚举）。满卡就是 78-100s。

## 6. 未解之谜

**Cascable Studio 在同款硬件同款卡冷启动下 5s 就进 LV。**

- 是 App Store 商业应用 → 一定用公开 API
- 是小独立开发商 → 没有 MFi / Apple 特权合作
- 但 Cascable 6.1 发布博客 Kennett 写过："we figured out what the problem was and were able to find the right person at Apple to help. This turned out to be a bug in iOS itself... the bug has been fixed in iOS 15" —— **他有 Apple 私下的技术支持，但没公开是什么方案**

我们尝试过的所有公开路径（respondsToSelector / control-auth / KVC private props / options dict）都不能复现他们的速度。

**可能的方向（未探索）：**
- App 启动时机的某种预热（在 discovery 之前更早的时机）
- Info.plist / entitlements 的某种配置
- 顺序敏感的 delegate/property 组合
- Cascable 拿到的是 Apple engineer 的**非公开配置建议**，未公开的技巧

## 7. 教训 & 下一步

**教训：**
1. **观测能力必须先建立** —— 没有 Phase A 我们根本判断不了任何后续改动有没有效
2. **私有 API 是噪音源** —— iOS 26 已经移除了 dump 里一半的 property，剩下的 semantic 也变了
3. **单次数据点不可信** —— iOS + USB + 相机固件三方交互的方差远大于我们代码的效果（30-190s 是常态）
4. **竞品是最强参照** —— Cascable/影控台 的存在证明"至少可以更快"，但也证明"至少要有 Apple 或社区特殊渠道"

**下一步的诚实评估：**

| 方向 | 收益 | 成本 | 推荐度 |
|---|---|---|---|
| **A. 撤掉不稳定的 KVC + 干净 baseline + UX 大改** | 用户体验立刻改善 | 半天 | ⭐⭐⭐⭐⭐ |
| **B. App 启动就预热 iOS 内部缓存** | 冷启动从 78s 逼近 46s | 1-2 天 | ⭐⭐⭐ |
| **C. 联系 Daniel Kennett 请教** | 可能获得关键提示 | 10 分钟 + 等待 | ⭐⭐⭐ |
| **D. Wi-Fi PTP-IP 优先，USB 降为兜底** | 秒连、无 iOS 限制 | Wi-Fi 配置 UX | ⭐⭐ |
| **E. 继续试其他私有 API** | 大概率还是噪音 | 不确定 | ⭐ |

## 8. 关键文件索引

| 文件 | 作用 |
|---|---|
| `packages/nikon_ptp_flutter/ios/Classes/IccDeviceCoordinator.swift` | 所有 Swift-side ICA 交互 + 日志 + KVC 实验 |
| `packages/nikon_ptp_flutter/ios/Classes/IccPtpPlugin.swift` | Pigeon HostApi 入口 + iOS 18+ 授权说明 |
| `packages/nikon_ptp_flutter/pigeons/icc_ptp.dart` | Pigeon schema（含 `setEagerPreOpen` + `onDiagnosticLog` + `onSessionOpenProgress`）|
| `packages/nikon_ptp_flutter/lib/src/icc_channel.dart` | Dart-side channel 单例 + 200 条日志 buffer |
| `packages/nikon_ptp_flutter/lib/src/icc_transport.dart` | `IccTransport` 实现 + openTimeout + progress/diagnostic streams |
| `packages/nikon_ptp_flutter/lib/src/icc_discovery.dart` | `IccCameraDiscovery.watch()` 生命周期挂 `setEagerPreOpen` |
| `packages/nikon_ptp/lib/src/client/nikon_z_client.dart` | `connect(onPhase:)` 相位回调 |
| `app/lib/features/connection/connection_controller.dart` | `_driveHandshake` (StreamController) + per-channel timeout copy + `_phaseLog` |
| `app/lib/features/connection/connecting_screen.dart` | `_ConnLog` stateful + 复制日志 + no-auto-nav to LV |

## 9. iccBuildTag 变更日志

Swift 常量 `IccDeviceCoordinator.iccBuildTag`，格式 `YYYY-MM-DD.N`：

| Tag | 内容 |
|---|---|
| `2026-08-20.a` | control-only auth + diagnostic log buffering |
| `2026-08-20.b` | 试 KVC `basicMediaModel` / `preheatMetadata` / `ptpEventForwarding` |
| `2026-08-20.c` | 试私有 `requestOpenSessionWithOptions:` 方法（iOS 26 已移除，fallback） |
| `2026-08-20.d` | **撤掉 .b/.c 噪音代码**，回到干净 public-API baseline；`command.error` 显式记录 `domain`/`code`（决定性区分 `-21249` 授权门 vs 阻塞后成功）；warmup 加 `-21249` 有界重试探针（指数退避 1→8s，110s 上限，~17 次封顶以不冲爆 200 行日志环）揭示真实门开启时间 |
| `2026-08-20.e` | **P1 control-only 探针**（私有 API 已授权，不上架）：开 session 前崩溃安全 KVC 设 `basicMediaModel=true` + `preheatMetadata=false`；`isEnumeratingContent` 遥测。**实测结论：`basicMediaModel` setter 在 iOS 26 存在且成功设置，但仍旧 102s → 确认是噪音；`preheatMetadata` 无 setter；`isEnumeratingContent` 整段阻塞里恒为 0（无用信号）。意外收获：日志抓到相机 USB 重枚举 —— conn#1(365B) 11ms 秒回、catalog 瞬间 100%；conn#2(531B 全量设备) 阻塞 102s、catalog 全程卡 0%。** |
| `2026-08-20.f` | **P2：怀疑是我们自己的 catalog 抑制导致卡死**。关掉 `responds(to:)` 对 `didAddItems:` 等的抑制（`suppressMediaCatalog=false`），测试「对 catalog 回调答 NO」是否正是让 ICA 空转 ~100s 才服务首条裸 PTP 的原因。撤掉 `.e` 的 KVC 噪音；stub 回调加日志（count + elapsed）。相对 `.d` 干净 baseline 的单一决定性变量 |
| `2026-08-20.g` | **P3：逆向 Cascable 7.2.2 IPA 后，直接抄它的有线连接**。地面真相：Cascable 用**同一套 ICA**（`ICDeviceBrowser`/`ICCameraDevice`/`requestSendPTPCommand:outData:completion:`），唯二结构差异 = ①用私有 `requestOpenSessionWithOptions:`（空/极简字典）开 session；②它的 `ICCPTPTransport` 跑 `pollForDeviceReadyWithBusyCodes:` —— 一个**容忍 busy 响应码、快速轮询**的就绪探测，而不是发一条命令干等 ICA hold ~100s。故 `.g` = options-open（空字典，`.c` 的猜键是错的）+ busy-code 就绪轮询（对 `0x2019 DeviceBusy`/`0x2003 SessionNotOpen`/`0x2004 InvalidTransactionID`/`-21249` 重试，busy 用 150ms 紧轮询、`-21249` 用退避）。每次发送记 `perSendMs`（决定性：首命令是被 ICA **阻塞 100s**，还是被相机**快速返回 busy**？）。保留 `suppressMediaCatalog=false`。**实测：`perSendMs=78855`，首条裸 PTP 被 ICA 阻塞 79s 后直接返回 OK、零 busy 码 → busy-poll 空转；单参 options 选择器不存在（回退，同 `.c`）→ options-open 从未真正跑过；抑制被洗清** |
| `2026-08-20.h` | **P4：运行时侦察**。`.g` 证明单参 `requestOpenSessionWithOptions:` 在 iOS 26.5.1 不存在（`.c`/`.g` 都静默回退），而 Cascable 真实 API 是**两参** `requestOpenSessionWithOptions:completion:`。盲调签名未知的私有方法有 block 签名崩溃风险（且可能连日志一起丢），故先做**零风险侦察**：运行时 dump 活体 `ICCameraDevice`/`ICDevice` 方法列表 + 类型编码（`introspect.sel`），拿到确切的开 session 私有选择器供 `.i` 调用。行为不变，仍 ~79s。**实测：`introspect.done matched=23`，确认两参 `requestOpenSessionWithOptions:completion:`（enc `v32@0:8@16@?24`）在 `ICCameraDevice`+`ICDevice` 都存在；`requestEnumerateContentWithOptions:completion:` 是独立 API（暗示 options-open 可能走不触发首阶段枚举的内部路径）** |
| `2026-08-20.i` | **P5：真正调用 Cascable 的两参 options-open**（`.h` 已确认存在）。改写 `requestOpenSessionLikeCascable`：`perform(_:with:with:)` 调 `requestOpenSessionWithOptions:completion:`，空字典 + `@convention(block) (NSError?) -> Void` completion；completion 回灌 `device:didOpenSessionWithError:`，用 `sessionOpenHandledIds` 按 deviceId 去重（该 open 会同时经 completion 与 delegate 两条路回来）。**不**调用 `requestEnumerateContent`。决定性量测：`perSendMs` 是否从 ~79s 下降 —— 若下降则 options-open 开了个延后枚举的控制 session；若仍 ~79s 则 options-open 单独不够 |

App 版本：`0.1.0+1` → `0.2.0+2` (2026-08-20.a) → `0.3.0+3` (.b) → `0.3.1+4` (.c) → `0.3.2+5` (.d) → `0.3.3+6` (.e) → `0.3.4+7` (.f) → `0.3.5+8` (.g) → `0.3.6+9` (.h) → `0.3.7+10` (.i)

### P0 测量：拿到日志后怎么读

`.d` 这一版的目的是**用一次真机日志一锤定音**当前诊断框架。复制日志后看这几行：

- **`command.error ... code=-21249`** 出现 → 是 **授权门**模型（ICA 主动拒绝）。此时看 `warmup.retry attempt=N elapsedMs=...` 序列：`warmup.done ok` 的 `elapsedMs` 就是**真实门开启时间**。若它 << 78s，说明重试本身就是解药。
- **完全没有 `-21249`**，只有 `warmup.start` 后隔很久才 `warmup.done ok respCode=0x2001` → 是**管道争用**模型（ICA 没拒绝，只是占着 USB 管道跑枚举）。此时授权门那条线彻底死，主攻方向转向 P2（缩小文件树）或 P3（Wi-Fi 绕开 ICA）。
- **`catalog.progress percent=...`**：整个等待窗口里若百分比一直 0 到最后才跳 → 卡在 Phase 1（storage handle 枚举，catalog 之前）；若缓慢 0→100 → Phase 2 仍在跑，`respondsToSelector` 门控没生效。

### P0 实测结论（`.d` 真机日志，2026-08-20，iPhone 17 / iOS 26.5.1 / Z 30 / 满卡）

**一锤定音：确认是「管道争用 / 首个 PTP 命令税」模型，授权门模型被证伪。** 决定性证据：

- `warmup.done · ok attempts=1 elapsedMs=96737 respCode=0x2001` —— 首个 GetDeviceInfo（tx=1）被 ICA hold 住 **96.7s** 后返回 **OK 0x2001**（不是拒绝）。
- 全日志 **零** `-21249`、**零** `command.error`、**零** `warmup.retry`，`attempts=1` —— ICA 从未拒绝命令，重试探针一次都没触发。
- 第二个 GetDeviceInfo（tx=2）只花 **0.8s**；随后 OpenSession/ChangeApplicationMode/DeviceReady 全部 ≤1s。**税只在首命令付一次。**
- `catalog.progress` 在整个 94s 阻塞窗口里一直 **0%**，阻塞释放后 ~200ms 内才跳到 20% —— 即 94s 花在 catalog **之前**的 Phase 1（GetStorageIDs/GetObjectHandles 内部枚举），它 gate 住 app 的首个 PTP 命令。
- 总连接 ~95s，其中「首命令之后的一切」合计 ~1s。

**修正（用户澄清后，2026-08-20）：** 全程只有一台 Z 30、一张卡；卡不是「满卡」，是 115G 中 95.4G 可用（约 17% 占用）。且 **Cascable Studio 在同一张卡、同样文件下冷启动 ~5s 连上**。这两点推翻了下面这个曾经的推论：

> ~~走 USB/ICA 时首命令阻塞 ~90s 无法用 app 侧任何手段消除，只能靠缩文件或换 Wi-Fi。~~

同卡同内容 Cascable 5s、我们 96.7s，差 ~19x → **存在一条 app 侧快速路径，是我们的 ICA 用法触发了 Phase-1 阻塞，而不是卡本身。** warmup 探针不省时间，但「~90s 不可避免」的说法是错的。

**新主攻方向：查明 Cascable 在同一张卡上如何绕开 Phase-1 阻塞。** 已确认 Cascable 有线连接也走 ImageCaptureCore/PTP（https://cascable.se/help/wired-cameras/ ），差异在**用法**不在框架。重点假设：

- **H1（最可疑）：** 我们用 `requestSendPTPCommand`（裸 PTP 透传）做 warmup，可能正是触发器 —— Apple 把裸 PTP 透传 gate 在完整 content catalog 之后。Cascable 或改用 ICA 原生 capture/tether 路径，或把透传推迟到 catalog 就绪后，从而首屏不阻塞。
- **H2：** 存在「仅控制 / 不枚举内容」的 session 打开方式（capture-only），我们没用上。
- **H3：** 真正的 gate 不是「catalog 完成」，而是别的可提前满足的条件。

**下一步：** ① 研究 spike：ICA 能否「开 session 做控制但不等 content catalog」+ Cascable 具体做法；② 零代码真机复核：**拔掉 SD 卡**以无卡态跑 `.d` 版连接计时（预期 <1s，与历史「拔卡 <1s」对齐，确认自身下限 —— 但这已知，优先级低于 ①）。

### P1 control-only 探针（`.e`，私有 API 已授权）

用户确认 **不上架 / 自用侧载** → 私有 API 解禁。`.e` 是一次**单变量**实验，在 `.d` 干净 baseline 上只加两件事：

1. **开 session 前**尝试把 `ICCameraDevice` 切进「仅控制」最小媒体模型：崩溃安全 KVC 设 `basicMediaModel=true`（用最小媒体模型，跳过 catalog）+ `preheatMetadata=false`（不预取逐文件元数据）。两个 setter 都先用 `responds(to: NSSelectorFromString("set<Key>:"))` 门控 —— 该 iOS 构建若无此私有键，静默跳过并记 `openSession.kvc skip key=... reason=no_setter`，绝不抛 `NSUnknownKeyException`。
2. **`isEnumeratingContent` 遥测**（读取同样崩溃安全，无 getter 记 `unknown`）：在 `openSession.enumState phase=preOpen` / `catalog.progress` / `warmup.start` / `warmup.done` 四处打点。

**这份日志怎么读（决定性）：**

- `basicMediaModel=true` 生效且有效 → `warmup.done ok elapsedMs` 应从 ~96s **骤降**，且全程 `isEnumeratingContent=0/false` → Phase-1 被跳过，H2 成立，主攻方向锁定「control-only open」。
- KVC 记 `openSession.kvc skip ... no_setter` → iOS 26 无此私有键，`basicMediaModel` 路死；但 `isEnumeratingContent` 若在阻塞窗口内为 `1/true`、释放后转 `0/false`，就**独立坐实** ~94s 确系 Phase-1 枚举（不再依赖 `catalog.progress` 的 200ms 间接推断），H1 优先级升到最高，转攻「裸 PTP 透传 gate 在 catalog 之后」。
- KVC 生效但**耗时不变**（仍 ~96s）→ `basicMediaModel` 是噪音（复现 `.b` 的不稳定），彻底放弃私有 KVC，全力 H1/H3。

无论哪条分支，`.e` 都把「Phase 1 有没有被跳过」从推断变成日志里的一个布尔值。

#### P1 实测结论（`.e` 真机日志，2026-08-20，iPhone 17 / iOS 26.5.1 / Z 30）

三条私有 API 线**全部走死**，但抓到一个更大的新线索：

- ❌ `basicMediaModel=true` —— **setter 在 iOS 26 确实存在**（`openSession.kvc set key=basicMediaModel value=true`，不是 no_setter），但 conn#2 仍旧阻塞 102s → **确认是噪音**（复现 `.b` 的不稳定），废弃。
- ❌ `preheatMetadata` —— `openSession.kvc skip ... no_setter`，iOS 26 无此键。
- ❌ `isEnumeratingContent` —— preOpen / warmup / 整段 102s 阻塞里**恒为 0**，甚至阻塞中也是 0 → 这个私有属性在 iOS 26 上不反映 Phase-1，**无用信号**，废弃。
- 🔑 **新线索（关键）：相机 USB 重枚举 + 两次连接天差地别。** 日志里 `device.didRemove` → `browser.didAdd`，前后两次 `GetDeviceInfo` 负载不同：
  - **conn#1（365B）**：`warmup.done ok elapsedMs=12`，`catalog.progress percent=100`（0→100 瞬间完成）—— **我们自己的栈上第一次跑出 12ms 秒连**（同一张卡！）。
  - **conn#2（531B，全量设备）**：`warmup.done ok elapsedMs=102082`，`catalog.progress` 全程 **0%**，阻塞释放后依然 0%。
  - 531B 才是 Z30 完整 DeviceInfo（capture/tether op 齐全，是我们控制要用的模式）；365B 是相机初始/精简 PTP 人格的瞬态。**税绑定在「全量 PTP + 有存储」那次枚举上。**

**重新定位：** 102s 阻塞对 `catalog%`（0）和 `isEnumeratingContent`（0）**双双不可见** → 它不是「内容 catalog 阶段」，而是 ICA 单纯把我们的**首条裸 `requestSendPTPCommand` 压在队列里** ~100s 不服务，内部在忙别的且不上报。这把 **H1（裸 PTP 透传被 gate）** 顶成头号嫌疑；但同时冒出一个「可能是我们自己作的」新怀疑 —— 见 P2。

### P2：会不会是我们自己的 catalog 抑制在作祟（`.f`）

对照 conn#1/conn#2 唯一的结构差异：conn#2 的 `catalog%` 从头到尾卡 0%，而**我们一直在用 `responds(to:)` 对 ICA 隐藏 `didAddItems:` / `didReceiveThumbnail:` / `deviceDidBecomeReadyWithCompleteContentCatalog:` 这些回调**（Phase B v1 的「骗过 ICA」hack）。

**新假设：** ICA 想投递 catalog 回调，但我们对这些 selector 答 `NO` → ICA 反复尝试/等到某个内部超时（~100s）才放弃并转而服务我们的首条裸 PTP。也就是说，**当初为「跳过 Phase 2 加速」而加的抑制，可能正是把连接拖到 ~100s 的元凶**（历史数据也隐约支持：无抑制时 78s，`.d` 带抑制反而 96s）。

`.f` 做**单一变量**验证：把抑制关掉（`suppressMediaCatalog=false`），让 ICA 正常投递 catalog 回调；stub 回调加 `catalog.didAddItems count=.. elapsedMs=..` 日志。撤掉 `.e` 的 KVC 噪音。

**怎么读 `.f` 日志（决定性）：**

- `warmup.done ok elapsedMs` 从 ~100s **骤降到几秒**，且看到 `catalog.didAddItems` 正常 fire、`catalog.progress` 从 0 往上走 → **抑制就是元凶**，直接删掉这个 hack（代价：Phase 2 会枚举缩略图，但如果连接因此秒开，完全值得）。
- 仍旧 ~100s，只是多了 `catalog.didAddItems` 日志 → 抑制无辜，锁定 **H1**：转攻「首条裸 PTP 透传为何被 ICA gate ~100s」以及 Cascable 如何用 ICA 却不吃这个税（下一步：不在 `didOpen+0ms` 立刻发裸 PTP，改等 `deviceDidBecomeReady:` 早回调再发，测 gate 是否是「过早发裸 PTP」触发的）。

### P3：逆向 Cascable 7.2.2 IPA，直接抄它的有线连接（`.g`）

拿到 Cascable Studio 7.2.2 解密 IPA 后逆向 `CascableCore.framework`（thin arm64，用 `python`（不是坏掉的 `python3` Store stub）跑字符串提取）。**地面真相推翻了之前「Cascable 不用 ICA」的错误结论** —— 那是坏解释器静默返回空、被误读成「0 命中」的产物。Cascable 的有线路径**和我们走同一套 ImageCaptureCore**：

- `ICDeviceBrowser`（ivar `_wiredCameraBrowser`）→ `ICCameraDevice` → 包进 `CBLWiredCameraDevice` / `GenericWiredCamera`。
- 传输类 `CascableCore.ICCPTPTransport`（文件 `Transport Helpers/ICCPTPTransport.swift`）。
- **所有 PTP 都走同一个公开 `requestSendPTPCommand:outData:completion:`** —— 和我们逐字一样，没有私有 passthrough 发送路径。
- 开 session 用**私有 `requestOpenSessionWithOptions:completion:`**，但**不引用任何 Apple 的 option-key 常量**（没有 `basicMediaModel`、没有 `ICEnumerationChronologicalOrder`…）→ options 字典是**空/极简**的，价值（若有）在不同的**内部路径**（`requestOpenSessionWithOptions:` → `loadDeviceModuleWithOptions:` → `bringupDeviceConnection`），不在字典内容。
- 连接序列：`requestOpenSessionWithOptions:` → `device:didOpenSessionWithError:` → `executeConnectionSteps:then:` → **`pollForDeviceReadyWithBusyCodes:then:queue:`** —— 一个**容忍 busy 响应码的重试轮询**（`0x2019 DeviceBusy`、`InvalidTransactionID`、Canon `NotReady`、"Session Already Open"），直到相机答就绪。
- Nikon 逻辑在自己的 ObjC 驱动 `CBLNikonCamera`（裸 Nikon PTP opcode + 长轮询事件循环）；**不抑制 ICA catalog 回调，也不设私有 KVC 属性**。

**唯二结构差异 vs 我们的代码：** (1) 开 session 变体（`.c` 用**猜的**键试过 → 不是解药）；(2) **busy-code 就绪轮询取代一条阻塞式 warmup**（真正没抄过 → `.g` 实验）。

`.g` 做法：
1. `requestOpenSessionLikeCascable`：`responds(to:)` 门控下改调 `requestOpenSessionWithOptions:`，传**空字典 `[:]`**（不是 `.c` 的猜键）；无此私有 API 时 fallback 到 `requestOpenSession()`。
2. `fireWarmup` 重写成 Cascable 式 busy-code 轮询：反复发 GetDeviceInfo，对 `0x2019`/`0x2003`/`0x2004`/`-21249` 判定为「可重试的 busy」→ busy 用 150ms 紧轮询、`-21249` 用退避，直到相机返回真正的 OK 或超 `warmupRetryDeadline`。
3. **每次发送记 `perSendMs`（本次发送耗时）+ `elapsedMs`（累计）**，节流打 `warmup.poll`。

**怎么读 `.g` 日志（决定性数据 = 首次发送的 `perSendMs`）：**

- **首条 `warmup.poll`/`warmup.done` 的 `perSendMs` ≈ 100000（~100s）** → ICA 仍旧把首条裸 PTP **压住 ~100s** 才返回；options-open 空字典没打开旁路，busy 轮询无从触发（因为命令根本没返回给我们）。→ 锁死 H1「ICA 在服务首条裸 PTP 前先跑完内部 Phase-1」，options 变体证伪，下一步只能攻「让 ICA 别把首条命令排在 Phase-1 之后」。
- **首条 `perSendMs` 很小（几十~几百 ms）却带 busy 响应码，之后紧轮询几次转 OK，总 `elapsedMs` << 100s** → options-open 让命令**透传到相机**、相机快速回 busy、我们的 busy 轮询把它接住 → **Cascable 式连接抄成功**，删掉旧的单发阻塞 warmup。
- 首条 `perSendMs` 小、直接 OK、无 busy → 更好，options-open 本身就绕开了 Phase-1。

无论哪条分支，`.g` 的 `perSendMs` 都把「首命令是被 ICA 阻塞 vs 被相机快速拒绝」这个此前靠间接推断的问题，变成日志里一个直接可读的数。

#### P3 实测结论（`.g` 真机日志，2026-08-20，iPhone 17 / iOS 26.5.1 / Z 30）

```
openSession.requestOpenSession · issued ... (options API unavailable, fallback)
warmup.done · ok attempts=1 perSendMs=78855 elapsedMs=78855 respCode=0x2001
```

三个硬结论：

1. **`perSendMs=78855`（~79s），`attempts=1`，零 busy 码** → ICA 把首条裸 PTP **压住 79s 后直接返回 OK 0x2001**，根本没返回 busy。**busy-code 轮询是空转** —— 没有 busy 可轮。Cascable 的 busy 容忍机制单独不是解药。
2. **`options API unavailable, fallback`** → 单参 `requestOpenSessionWithOptions:` 在 iOS 26.5.1 **不存在**，回退到普通开法。核对 git：**`.c` 用的也是单参选择器、也一样回退** → **`.c` 和 `.g` 从未真正跑过 options 开法**。Cascable 的真实 API 是**两参** `requestOpenSessionWithOptions:completion:`，此前把参数个数搞错了。
3. **抑制被洗清（H4 证伪）**：`.g` 关了抑制（`suppressMediaCatalog=false`），日志里 `catalog.didAddItems count=1` 正常 fire，但**仍旧 79s** → 「是我们自己抑制 catalog 导致卡死」不成立。79s 是 ICA 服务首条裸 PTP 的固有税。

逆向得出的两个结构性差异，现在一个空转（busy-poll）、一个**参数写错从未测过**（options-open）。真正的杠杆 `requestOpenSessionWithOptions:completion:` 一次都没试过 → 见 §P4。

### P4：运行时侦察，拿到 iOS 26 上真实可调的私有开法（`.h`）

盲调一个签名未知的私有 `...completion:` 方法有风险：block 参数个数/类型猜错就崩，甚至可能连诊断日志一起丢。`method_getTypeEncoding` 能确认「第 2 个参数是不是 block」，但**看不到 block 内部的参数签名**（所有 block 在方法编码里都是 `@?`）。所以 `.h` 不赌，先做**零风险侦察**：

- `dumpPrivateSelectors(for:)`：运行时沿 `ICCameraDevice` → `ICDevice` → … 的类继承链走 `class_copyMethodList`，把选择器名里含 `opensession`/`option`/`bringup`/`module`/`tether` 的方法连同 `method_getTypeEncoding` 一起打成 `introspect.sel class=.. sel=.. enc=..`。一次性（静态 `didDumpPrivateSelectors` 门控），关键词收窄以免刷爆 Dart 侧 200 行日志环。
- 本版**行为不变**：仍走公开 `requestOpenSession()`、仍付 ~79s 税。价值全在 `introspect.sel` 那几行。

**怎么读 `.h` 日志：**

- 找 `introspect.sel ... sel=requestOpenSessionWithOptions:completion:` → 确认这个两参 API 在 iOS 26.5.1 **确实存在**，`.i` 就用它（空字典 + `(NSError?) -> Void` completion）。
- 若只看到别的开法变体（如某个 `...bringup...` / `loadDeviceModuleWithOptions:` / ICA 原生 tether），那就是我们没想到的私有面 → 择优在 `.i` 里试。
- 若整条继承链**一个 options/bringup 开法都没有** → iOS 26 的 `ICCameraDevice` 根本不暴露 Cascable 那套 API（Cascable 可能链接了不同/更老的 ICA，或用了 ICImageCapture 之外的私有栈）→ 转向别的思路（如推迟首条裸 PTP、等 `deviceDidBecomeReady:` 早回调再发）。

`.h` 把「iOS 26 上到底有哪些私有开 session 入口」从猜测变成日志里一份确定的清单。

**`.h` 实测结论（真机日志，2026-08-20，iPhone 17 / iOS 26.5.1 / Z 30）：**

- `introspect.done matched=23`。关键命中：
  - `class=ICCameraDevice sel=requestOpenSessionWithOptions:completion: enc=v32@0:8@16@?24`（两参：dict@16 + block@?24，返回 void）—— **两参 options-open 在 iOS 26.5.1 确实存在**，`ICDevice` 上也有同名同签名。
  - `requestEnumerateContentWithOptions:completion:` 是**独立**的内容枚举 API。open 与 enumerate 分家 → 强烈暗示 options-open 可以只开控制 session、把 ~79s 的首阶段存储枚举**延后/跳过**。
  - 还命中 `requestEnableTethering`/`requestDisableTethering`/`tetheredCaptureEnabled`（ICA 原生 tether 面）与 `autoOpenSession`/`setAutoOpenSession:`/`openSessionPending`（自动开 session 面）—— 作为 `.i` 之后的备选杠杆。
- 行为仍 ~79s（`perSendMs=78616`），符合预期（本版只侦察不改开法）。

→ 结论：`.i` 直接调这个确认存在的两参选择器，第一次真正跑 Cascable 的 options-open。

### P5：真正调用 Cascable 两参 options-open（`.i`）

`.i` 终于第一次真正执行 Cascable 的开法（`.c`/`.g` 因选择器参数写错都静默回退到无参 open，从未跑过）。

- 改写 `requestOpenSessionLikeCascable`：`responds(to:)` 命中两参 `requestOpenSessionWithOptions:completion:` 后，用 `perform(_:with:with:)` 传**空字典** + `@convention(block) (NSError?) -> Void` completion。
- 该 open 会**同时**经 completion block 和 `device:didOpenSessionWithError:` delegate 两条路回来 → completion 里把结果回灌 delegate，delegate 顶部用 `sessionOpenHandledIds`（按 deviceId）去重，保证 warmup / pigeon completion 只跑一次。每次 fresh open 开头 `sessionOpenHandledIds.remove(deviceId)` 清位。
- **不**调用 `requestEnumerateContentWithOptions:` —— 赌的就是「只开控制 session、不主动触发枚举」。

**怎么读 `.i` 日志：**

- 找 `openSession.requestOpenSessionWithOptions ... completion=block (Cascable two-arg)` → 确认这次真的走了两参 options-open（不是回退）。
- 找 `openSession.optionsCompletion fired ...` → completion block 正常回调（证明 block 签名对，没崩）。
- **决定性**：`warmup.done ... perSendMs=?`
  - `perSendMs` 从 ~79s **大幅下降** → options-open 开的是个延后枚举的控制 session，Cascable 的 5s 之谜破解，收工。
  - 仍 ~79s → options-open **单独不够**。下一步候选：推迟首条裸 PTP、等 `deviceDidBecomeReady:` / catalog 早回调再发；或转 ICA 原生 tether（`requestEnableTethering`）。

---

## 附录 A：Apple ICA 两阶段枚举模型（推断）

基于实测数据（78s 冷 / 46s warm / 空卡秒开 / respondsToSelector 关掉 Phase 2 但 Phase 1 仍在）推断：

```
requestOpenSession()
  ↓
didOpenSessionWithError(nil)  ← 1ms 内触发（session 建立）
  ↓
用户调 requestSendPTPCommand   ← 命令进入 ICA 内部队列
  ↓
  [PHASE 1: 内部 storage 枚举]  ← 78s 冷 / 46s warm
  GetStorageIDs → GetStorageInfo → GetObjectHandles per storage
  ├─ 用户 PTP 命令被 hold 住返回 -21249
  ├─ ICCameraDevice.contentCatalogPercentCompleted 尚未开始
  └─ 无 delegate 回调，无 KVO 触发
  ↓
  [PHASE 1 完成，用户 PTP 命令被放行]
  ↓
用户 PTP 命令返回（GetDeviceInfo response 531 bytes）
  ↓
  [PHASE 2: per-file catalog 枚举]  ← respondsToSelector 已禁掉
  contentCatalogPercentCompleted: 0 → 1 → 3 → ... → 100
  didAddItems: / didReceiveMetadata: / didReceiveThumbnail: 逐个 fire
  最终 deviceDidBecomeReadyWithCompleteContentCatalog: 触发
```

**Phase 1 是无法从公开 API 跳过的** —— 这是 Apple Radar FB7593726 的核心问题。所有已知优化路径都无法跳过 Phase 1。

## 附录 B：数据一览

真机实测数据（iPhone 17, iOS 26.5.1, Nikon Z 30, 同一张 115G 卡 / 95.4G 可用，约 17% 占用）：

| 场景 | warmup elapsedMs | 备注 |
|---|---|---|
| Baseline vanilla（无任何 tweak） | 103,438 | Phase A 前 |
| Phase A 观测 + Phase B v1 respondsToSelector | 78,344 | 稳定 baseline |
| + Phase B v2 eager pre-open | 78,689 | Total time 相同，只是税挪到用户 tap 前 |
| + Phase B v3 control auth（冷启动） | 78,708 | 授权确认 status=3 |
| + Phase B v3 control auth（未重启第 2 次） | 45,996 | iOS 缓存生效 |
| + Phase B v3 control auth（未重启第 3 次） | 46,081 | 缓存稳定 |
| + Phase B v4 KVC basicMediaModel（第 1 次） | 78,849 | |
| + Phase B v4 KVC basicMediaModel（第 2 次） | **29,919** | 一度让人以为找到银弹 |
| + Phase B v4 KVC basicMediaModel（第 3 次） | **191,201** | 比 baseline 慢 2.4 倍 |
| Phase B v5 options API attempt | 191,201 (fallback) | iOS 26 移除了此方法 |
| **`.d` 干净 baseline（实测）** | **96,737** | **零 -21249，attempts=1，OK 0x2001；管道争用模型确认；tx=2 仅 0.8s** |
| **`.e` conn#1（365B 瞬态枚举）** | **12** | **同卡秒连！catalog 0→100 瞬间；basicMediaModel=true 已设** |
| **`.e` conn#2（531B 全量设备）** | **102,082** | **重枚举后的全量人格；catalog 全程 0%；isEnumeratingContent 恒 0；basicMediaModel 无效 → 噪音** |
| **Cascable Studio（同卡对照，已确认）** | **~5,000** | **同一张卡（95.4G 可用）冷启动;也走 ICA/PTP → 证明 app 侧存在快速路径,我们的用法有问题** |
| **拔掉 SD 卡（对照）** | **<1,000** | Phase 1 无东西可枚举 |
