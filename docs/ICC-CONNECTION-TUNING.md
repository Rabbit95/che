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

App 版本：`0.1.0+1` → `0.2.0+2` (2026-08-20.a) → `0.3.0+3` (.b) → `0.3.1+4` (.c) → `0.3.2+5` (.d)

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

**推论（重要且不乐观）：** 走 USB / ICA 时，满卡 Z 30 的首命令阻塞 ~90s 无法用 app 侧任何手段消除 —— 所有 PTP 命令（含开启控制的 ChangeApplicationMode）都排在完整 catalog 之后，这 94s 内相机不接受任何控制命令。warmup 探针不省时间，只是给这笔税贴了标签。真正的解法只有两条：**(a) 减少卡上文件（Phase 1 无东西可枚举 → 秒开，已被「拔卡 <1s」佐证）**，或 **(b) 换传输层（Wi-Fi PTP-IP 绕开 ICA，P3）**。

**Cascable 对照存疑：** 研究表明 Cascable 的 USB 连接**也走 ImageCaptureCore/PTP**（见 https://cascable.se/help/wired-cameras/ ），因此附录 B 里「~5s + Apple 私下支持」的说法**不可靠**，很可能是小卡/空卡或 Wi-Fi 下的测量。待验证实验：用 Cascable Studio 连**同一张满卡** Z 30 冷启动计时 —— 若也 ~90s，则我们与 Cascable 在满卡 USB 下本就同速。

**下一步（零代码，需真机配合）：** ① 换一张近空卡冷启动连接计时（预期秒开，确认文件数因果）；② Cascable 连同一张满卡计时（消歧 Cascable 是否有我们没找到的招）。这两个数据点决定 P2（缩文件树）vs P3（Wi-Fi）的主攻方向。

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

真机实测数据（iPhone 17, iOS 26.5.1, Nikon Z 30, 满 SD 卡）：

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
| **Cascable Studio（对照，存疑）** | ~5,000？ | Cascable USB 也走 ICA/PTP；此数很可能是小卡/Wi-Fi，待同满卡 A/B 复核 |
| **拔掉 SD 卡（对照）** | **<1,000** | Phase 1 无东西可枚举 |
