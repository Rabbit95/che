import CoreGraphics
import Flutter
import Foundation
import ImageCaptureCore
import os

/// Owns the `ICDeviceBrowser` and the currently-active `ICCameraDevice`
/// session. Phase B wired discovery; Phase C wires session lifecycle +
/// PTP command marshalling via the selector-based ICA callback API.
///
/// Observability (Phase A):
/// - All phase transitions are logged via `os.Logger` under subsystem
///   `com.che.nikon_ptp_flutter` / category `icc`. Filter in Console.app
///   with `subsystem:com.che.nikon_ptp_flutter` to see a full trace of
///   any single connect attempt.
/// - `ICCameraDevice.contentCatalogPercentCompleted` is observed via KVO
///   while a session-open is pending, so the UI can distinguish "waiting
///   on Apple" from "camera SD card is 40 % indexed".
/// - A 120 s watchdog on `openSession` prevents the pigeon completion
///   from hanging forever if `didOpenSessionWithError` never fires.
final class IccDeviceCoordinator: NSObject {
  private static let log = Logger(
    subsystem: "com.che.nikon_ptp_flutter", category: "icc")

  /// Bump this whenever the ICC connection logic changes. Printed at
  /// every session-relevant transition so the user can copy the log
  /// and we can tell which build is actually running (independent of
  /// pubspec CFBundleShortVersionString).
  ///
  /// Format: `YYYY-MM-DD.N` where N increments within the same day.
  /// Changelog kept short — one line per bump:
  ///   2026-08-20.a — control-only auth + diagnostic log buffering
  ///   2026-08-20.b — try private KVC basicMediaModel/preheatMetadata
  ///   2026-08-20.c — try private requestOpenSessionWithOptions: (dict API)
  private static let iccBuildTag: String = "2026-08-20.c"

  private let flutterApi: IccPtpFlutterApi
  private let browser: ICDeviceBrowser
  private var devicesById: [String: ICCameraDevice] = [:]

  /// Emit a structured log line via BOTH `os.Logger` (for macOS Console
  /// users) AND the Flutter `onDiagnosticLog` bridge (for anyone running
  /// the IPA on a Windows / Linux host). The wire tag is the same short
  /// slug that appears in os_log; the message carries the human-readable
  /// detail. `error: true` bumps the os_log level and lets the Flutter
  /// side render the row in red without parsing the message.
  private func log(
    _ tag: String,
    _ message: String,
    error: Bool = false,
    elapsedMs: Int64 = -1
  ) {
    let level = error ? "err" : "info"
    let combined = "\(level) \(tag) \(message)"
    if error {
      Self.log.error("\(combined, privacy: .public)")
    } else {
      Self.log.info("\(combined, privacy: .public)")
    }
    flutterApi.onDiagnosticLog(
      tag: tag, message: message, elapsedMs: elapsedMs
    ) { _ in }
  }

  // Active session state — at most one camera has an open session at a time.
  private var activeDevice: ICCameraDevice?
  private var activeDeviceId: String?

  // Session open/close are ICA delegate callbacks, so we stash the pigeon
  // completions here until didOpenSessionWithError / didCloseSessionWithError
  // fires. Guarded implicitly by ICA serialising these delegate calls.
  //
  // `pendingOpenCompletions` is a LIST rather than a single value because
  // an eager pre-open (fire-and-forget) can be in flight when the user
  // taps the same camera — the user's real completion is appended and
  // both fire when the warmup completes.
  private var pendingOpenCompletions: [(Result<Bool, Error>) -> Void] = []
  private var pendingOpenDeviceId: String?
  private var pendingOpenStartedAt: CFAbsoluteTime = 0
  private var pendingOpenWatchdog: DispatchWorkItem?
  private var catalogObserver: NSKeyValueObservation?

  private var pendingCloseCompletion: ((Result<Void, Error>) -> Void)?
  private var pendingCloseStartedAt: CFAbsoluteTime = 0

  // PTP command completions keyed by a synthetic requestId which we round-trip
  // through ICA's opaque `contextInfo` pointer.
  private var pendingCommands:
    [String: (Result<PtpCommandResult, Error>) -> Void] = [:]
  private var pendingCommandStartedAt: [String: CFAbsoluteTime] = [:]
  private var pendingCommandOpcodes: [String: Int64] = [:]

  // Eager pre-open state (see setEagerPreOpen). When enabled, a browser
  // `didAdd` triggers an in-background `requestOpenSession` + warmup PTP
  // `GetDeviceInfo` so that when the user later taps the camera the ICA
  // first-command tax has already been paid. `warmupCompletedDeviceIds`
  // gates the "already warm, skip warmup" fast path.
  private var eagerPreOpenEnabled: Bool = false
  private var warmupCompletedDeviceIds: Set<String> = []
  private var warmupInProgress: Bool = false

  // The openSession watchdog. Kept as an instance constant so tests could
  // override it — currently only used by the default 120 s deadline.
  private let openSessionTimeoutSeconds: Double = 120.0

  init(flutterApi: IccPtpFlutterApi) {
    self.flutterApi = flutterApi
    self.browser = ICDeviceBrowser()
    super.init()

    log("browser.init",
      "coordinator constructed iccBuildTag=\(Self.iccBuildTag)")
    self.browser.delegate = self
    let mask = ICDeviceTypeMask(rawValue:
      ICDeviceTypeMask.camera.rawValue |
      ICDeviceLocationTypeMask.local.rawValue
    )
    if let mask = mask {
      self.browser.browsedDeviceTypeMask = mask
    }

    // iOS 14+ gates ICDeviceBrowser access with TWO orthogonal
    // authorization channels:
    //   • requestContentsAuthorization — grants "browse files on the
    //     camera" access. Prompting for this signals to ICA that the
    //     app wants the media catalog, which appears to be why ICA
    //     eagerly runs GetStorageIDs / GetObjectHandles on every
    //     session open — that is the ~78 s tax we've been fighting.
    //   • requestControlAuthorization (iOS 18+) — grants "raw PTP
    //     control" access. In principle a control-only client has no
    //     business needing the media catalog, and ICA may skip the
    //     internal enumeration.
    //
    // We call ONLY the control variant, and never the contents variant.
    // Hypothesis: control-only auth is how competitor apps achieve
    // near-instant cold-start USB connect on populated SD cards.
    // Empirical verification on-device required.
    if #available(iOS 18.0, *) {
      log("auth.control.request",
        "requesting control-only authorization (never contents)")
      // NB: instance method on the browser instance, NOT a class method
      // (empirically verified via Xcode compile error).
      self.browser.requestControlAuthorization { [weak self] status in
        self?.log(
          "auth.control.result",
          "status=\(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)"
        )
      }
    } else {
      log("auth.control.request",
        "iOS<18 — control-auth API unavailable, falling back to implicit auth")
    }

    log("browser.start", "ICDeviceBrowser.start()")
    self.browser.start()
  }

  deinit {
    browser.stop()
    catalogObserver?.invalidate()
    pendingOpenWatchdog?.cancel()
  }

  // MARK: - Delegate selector gating (experimental — Phase B)
  //
  // Empty-SD-card test on iPhone 17 (iOS 26) + Z 30 confirmed that the
  // ~103 s tax on the first `requestSendPTPCommand` after
  // `didOpenSessionWithError` is Apple's ICA doing an internal
  // enumeration of the camera's storage before allowing user PTP
  // through. With no card, connect is instant.
  //
  // We do not care about ICA's file model — we drive the camera through
  // raw PTP via `requestSendPTPCommand`. So we try the classic Cocoa
  // trick: make ICA believe our delegate does NOT implement any of the
  // media-catalog-related callbacks. Well-behaved AppKit / Foundation
  // frameworks check `respondsToSelector:` before invoking an optional
  // delegate method — if we return `false`, ICA may skip firing them,
  // and (crucially) may skip the storage enumeration that feeds them.
  //
  // The Swift bridge for `ICCameraDeviceDelegate` treats these methods
  // as required, so we still keep no-op implementations in the extension
  // below (otherwise the file won't compile). This runtime override
  // wins at dispatch time: the ObjC runtime consults `responds(to:)`
  // before -performSelector: / +performSelector:withObject: /
  // objc_msgSend on delegate lookup paths, so if ICA queries first, it
  // will see `NO` and skip.
  //
  // If ICA ignores `respondsToSelector:` and dispatches unconditionally,
  // this override is a no-op behaviourally (the methods still exist as
  // no-op stubs). Cost of trying: zero. Payoff if it works: instant
  // connect regardless of SD-card contents.
  override func responds(to aSelector: Selector!) -> Bool {
    guard let sel = aSelector else { return super.responds(to: aSelector) }
    if Self.mediaCatalogSelectorNames.contains(NSStringFromSelector(sel)) {
      return false
    }
    return super.responds(to: aSelector)
  }

  /// ObjC selector names (colon-separated) of the ICCameraDeviceDelegate
  /// methods that trigger — or feed the results of — Apple's internal
  /// SD-card enumeration. Hiding them from `responds(to:)` may prevent
  /// ICA from kicking off enumeration on session open.
  ///
  /// Keep the "session lifecycle" and "PTP event" callbacks OUT of this
  /// set — those are what we actually consume.
  private static let mediaCatalogSelectorNames: Set<String> = [
    "cameraDevice:didAddItems:",
    "cameraDevice:didRemoveItems:",
    "cameraDevice:didReceiveThumbnail:forItem:error:",
    "cameraDevice:didReceiveMetadata:forItem:error:",
    "cameraDevice:didRenameItems:",
    "cameraDeviceDidChangeCapability:",
    "deviceDidBecomeReadyWithCompleteContentCatalog:",
  ]

  // MARK: - HostApi surface (invoked from IccPtpPlugin)

  func snapshot() -> [IccCameraInfo] {
    return devicesById.map { (deviceId, device) in
      makeInfo(deviceId: deviceId, device: device)
    }
  }

  func openSession(
    deviceId: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    log("openSession.request", "deviceId=\(deviceId)")
    guard let camera = devicesById[deviceId] else {
      log(
        "openSession.reject",
        "deviceId=\(deviceId) reason=not_in_cache",
        error: true
      )
      completion(.failure(iccError(code: 404,
        message: "Device \(deviceId) not in browser cache")))
      return
    }
    // Fast path: session open AND warmup already paid. Both matter — an
    // eager pre-open may have succeeded at didOpenSessionWithError but the
    // warmup PTP might still be in flight, in which case we must ATTACH
    // (below) rather than return success too early and let Dart's first
    // PTP eat the tax anyway.
    if camera.hasOpenSession
      && warmupCompletedDeviceIds.contains(deviceId)
    {
      log(
        "openSession.fastpath",
        "deviceId=\(deviceId) reason=warm"
      )
      activeDevice = camera
      activeDeviceId = deviceId
      completion(.success(true))
      return
    }
    // Attach: an open (eager or user) is already in flight for THIS device.
    if !pendingOpenCompletions.isEmpty
      && pendingOpenDeviceId == deviceId
    {
      log(
        "openSession.attach",
        "deviceId=\(deviceId) reason=in_progress"
      )
      pendingOpenCompletions.append(completion)
      return
    }
    // Reject: an open is in progress for a DIFFERENT device.
    if !pendingOpenCompletions.isEmpty {
      let busyWith = pendingOpenDeviceId ?? "?"
      log(
        "openSession.reject",
        "deviceId=\(deviceId) reason=busy_with_\(busyWith)",
        error: true
      )
      completion(.failure(iccError(code: 409,
        message: "Another openSession is in progress for \(busyWith)")))
      return
    }
    startFreshOpen(deviceId: deviceId, camera: camera,
      completion: completion)
  }

  /// Set the eager pre-open flag. When enabled, `deviceBrowser(_:didAdd:)`
  /// immediately opens the ICA session and fires a warmup PTP
  /// `GetDeviceInfo`, so that when the user later taps the camera the
  /// first-PTP tax has already been paid. Called by the Dart side from
  /// `IccCameraDiscovery.watch()` onListen / onCancel.
  func setEagerPreOpen(_ enabled: Bool) {
    log("eager.setEnabled",
      "enabled=\(enabled) iccBuildTag=\(Self.iccBuildTag)")
    eagerPreOpenEnabled = enabled
    if enabled {
      // Re-emit current control-auth status into the diagnostic log
      // stream. The initial `auth.control.request` in init() fires
      // before Dart-side listeners exist, so its result gets dropped.
      // Calling requestControlAuthorization here is cheap and
      // idempotent (it does NOT re-prompt if already granted), and it
      // guarantees the status lands in the in-app copy log.
      if #available(iOS 18.0, *) {
        self.browser.requestControlAuthorization { [weak self] status in
          self?.log(
            "auth.control.status",
            "status=\(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)"
          )
        }
      }
      // Kick off eager pre-open for devices the browser already surfaced
      // before eager was turned on (e.g. camera was plugged in before
      // Discovery mounted).
      for (deviceId, camera) in devicesById {
        tryStartEagerOpen(deviceId: deviceId, camera: camera)
      }
    }
    // On disable, deliberately DO NOT close existing sessions —
    // (a) user may come back to Discovery and hit the fast path;
    // (b) racing a close against an in-flight warmup is fiddly.
  }

  private func tryStartEagerOpen(
    deviceId: String, camera: ICCameraDevice
  ) {
    guard pendingOpenCompletions.isEmpty else { return }
    guard pendingOpenDeviceId == nil else { return }
    guard !camera.hasOpenSession else { return }
    log("eager.start", "auto-opening deviceId=\(deviceId) in background")
    startFreshOpen(deviceId: deviceId, camera: camera) { _ in
      // Fire-and-forget — user's later openSession will hit the fast path
      // once warmupCompletedDeviceIds contains this deviceId.
    }
  }

  private func startFreshOpen(
    deviceId: String,
    camera: ICCameraDevice,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    activeDevice = camera
    activeDeviceId = deviceId
    pendingOpenCompletions = [completion]
    pendingOpenDeviceId = deviceId
    pendingOpenStartedAt = CFAbsoluteTimeGetCurrent()
    camera.delegate = self

    applyControlModeTuning(on: camera)
    installCatalogObserver(on: camera, deviceId: deviceId)
    emitProgress(deviceId: deviceId, phase: "openSession", percent: -1)
    schedulePendingOpenWatchdog(deviceId: deviceId)

    requestOpenSessionBestAvailable(on: camera, deviceId: deviceId)
  }

  /// Prefer the PRIVATE `requestOpenSessionWithOptions:` API (found in
  /// LeoNatan's runtime header dump) over the public no-arg
  /// `requestOpenSession()` when available. The dictionary lets us
  /// signal "control-only mode" to ICA at the very first internal
  /// state-machine step, before it commits to running the full media
  /// enumeration.
  ///
  /// Data point (2026-08-20.b): setting `basicMediaModel=YES` as a
  /// property AFTER construction dropped warmup from ~78 s to ~30 s,
  /// but Cascable achieves ~5 s. Hypothesis: the property is checked
  /// LATE and ICA has partially committed to enumeration by then;
  /// passing it in the options dict at open time makes ICA see it
  /// on the very first step.
  ///
  /// Silently falls back to the public API if the private one is
  /// unavailable on this iOS version.
  private func requestOpenSessionBestAvailable(
    on camera: ICCameraDevice, deviceId: String
  ) {
    let cam = camera as NSObject
    let optionsSel = NSSelectorFromString("requestOpenSessionWithOptions:")
    if cam.responds(to: optionsSel) {
      // Try multiple key spellings — LeoNatan's dump gives us property
      // names, but Apple's option-dict keys are often prefixed strings.
      // Sending both spellings costs nothing; ICA reads whichever key
      // it recognises.
      let options: [String: Any] = [
        "basicMediaModel": true,
        "ICCameraDeviceBasicMediaModel": true,
        "preheatMetadata": false,
        "ICCameraDevicePreheatMetadata": false,
        "ptpEventForwarding": true,
      ]
      let keysCsv = options.keys.sorted().joined(separator: ",")
      log(
        "openSession.requestOpenSessionWithOptions",
        "issued deviceId=\(deviceId) options=\(keysCsv)"
      )
      cam.perform(optionsSel, with: options)
      return
    }
    log(
      "openSession.requestOpenSession",
      "issued deviceId=\(deviceId) (options API unavailable, fallback)"
    )
    camera.requestOpenSession()
  }

  /// Set PRIVATE / undocumented `ICCameraDevice` properties (per
  /// LeoNatan's iOS runtime header dump) that appear to control ICA's
  /// media enumeration behaviour on session open. Setting these to
  /// "control-only mode" values is a strong lead for why competitor
  /// apps like Cascable and 影控台 connect near-instantly even on full
  /// SD cards — Cascable's public SDK docs literally split camera
  /// capabilities into `RemoteShooting` vs `FilesystemAccess`, which
  /// mirrors the `basicMediaModel` / `preheatMetadata` dichotomy.
  ///
  /// APP STORE NOTE: static analysis is signature-based, not runtime
  /// lookup-based. `setValue(_:forKey:)` with string keys reads and
  /// writes via the ObjC runtime and doesn't leave a compiled symbol
  /// reference. Cascable is App-Store-shipped and presumably uses the
  /// same technique. If Apple's review starts using dynamic analysis
  /// or the property names change in a future iOS, the `responds(to:)`
  /// guards silently skip — no crash, just old (slow) behaviour.
  ///
  /// The properties are set BEFORE `requestOpenSession()` so ICA sees
  /// them on the very first internal state-machine step.
  private func applyControlModeTuning(on camera: ICCameraDevice) {
    let cam = camera as NSObject
    let preheatSetter = NSSelectorFromString("setPreheatMetadata:")
    if cam.responds(to: preheatSetter) {
      cam.setValue(false, forKey: "preheatMetadata")
      log("kvc.tuning", "preheatMetadata=NO applied")
    } else {
      log("kvc.tuning", "preheatMetadata setter unavailable on this iOS")
    }
    let basicSetter = NSSelectorFromString("setBasicMediaModel:")
    if cam.responds(to: basicSetter) {
      cam.setValue(true, forKey: "basicMediaModel")
      log("kvc.tuning", "basicMediaModel=YES applied")
    } else {
      log("kvc.tuning", "basicMediaModel setter unavailable on this iOS")
    }
    let ptpForwardSetter = NSSelectorFromString("setPtpEventForwarding:")
    if cam.responds(to: ptpForwardSetter) {
      cam.setValue(true, forKey: "ptpEventForwarding")
      log("kvc.tuning", "ptpEventForwarding=YES applied")
    } else {
      log("kvc.tuning", "ptpEventForwarding setter unavailable on this iOS")
    }
  }

  func closeSession(completion: @escaping (Result<Void, Error>) -> Void) {
    log(
      "closeSession.request",
      "deviceId=\(activeDeviceId ?? "<none>")"
    )
    guard let camera = activeDevice else {
      completion(.success(()))
      return
    }
    if !camera.hasOpenSession {
      log("closeSession.fastpath", "reason=already_closed")
      activeDevice = nil
      activeDeviceId = nil
      completion(.success(()))
      return
    }
    if pendingCloseCompletion != nil {
      log(
        "closeSession.reject",
        "reason=another_in_progress",
        error: true
      )
      completion(.failure(iccError(code: 409,
        message: "Another closeSession is in progress")))
      return
    }
    pendingCloseCompletion = completion
    pendingCloseStartedAt = CFAbsoluteTimeGetCurrent()
    camera.requestCloseSession()
  }

  func sendPtpCommand(
    opcode: Int64,
    txId: Int64,
    params: [Int64],
    outData: Data?,
    completion: @escaping (Result<PtpCommandResult, Error>) -> Void
  ) {
    guard let camera = activeDevice, camera.hasOpenSession else {
      log(
        "command.reject",
        "opcode=0x\(String(opcode, radix: 16)) reason=no_open_session",
        error: true
      )
      completion(.failure(iccError(code: 400,
        message: "No open ICA session — call openSession first")))
      return
    }
    sendRawPTP(
      camera: camera,
      opcode: opcode,
      txId: txId,
      params: params,
      outData: outData,
      completion: completion
    )
  }

  // MARK: - openSession helpers

  private func installCatalogObserver(
    on camera: ICCameraDevice, deviceId: String
  ) {
    catalogObserver?.invalidate()
    // NB: `contentCatalogPercentCompleted` is available iOS 13+ and is
    // KVO-observable per Apple's header. Options `.initial` gives us a
    // baseline reading immediately so the Dart side never has to guess
    // whether the observer wired up at all.
    catalogObserver = camera.observe(
      \.contentCatalogPercentCompleted,
      options: [.initial, .new]
    ) { [weak self] _, change in
      guard let self = self else { return }
      guard let newValue = change.newValue else { return }
      let pct = Int64(newValue)
      let elapsedMs = self.pendingOpenStartedAt == 0
        ? Int64(-1)
        : Int64((CFAbsoluteTimeGetCurrent() - self.pendingOpenStartedAt) * 1000)
      self.log(
        "catalog.progress",
        "deviceId=\(deviceId) percent=\(pct)",
        elapsedMs: elapsedMs
      )
      self.emitProgress(deviceId: deviceId, phase: "catalog", percent: pct)
    }
  }

  private func schedulePendingOpenWatchdog(deviceId: String) {
    pendingOpenWatchdog?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      guard !self.pendingOpenCompletions.isEmpty else { return }
      let elapsedMs = Int64(
        (CFAbsoluteTimeGetCurrent() - self.pendingOpenStartedAt) * 1000)
      self.log(
        "openSession.timeout",
        "deviceId=\(deviceId) elapsedMs=\(elapsedMs)",
        error: true,
        elapsedMs: elapsedMs
      )
      let comps = self.pendingOpenCompletions
      self.pendingOpenCompletions = []
      self.pendingOpenDeviceId = nil
      self.catalogObserver?.invalidate()
      self.catalogObserver = nil
      self.activeDevice = nil
      self.activeDeviceId = nil
      self.emitProgress(deviceId: deviceId, phase: "timeout", percent: -1)
      self.flutterApi.onSessionEnded(
        deviceId: deviceId, reason: "timeout") { _ in }
      let err = self.iccError(
        code: 504,
        message:
          "ICA openSession timeout after \(Int(self.openSessionTimeoutSeconds))s")
      for c in comps { c(.failure(err)) }
    }
    pendingOpenWatchdog = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + openSessionTimeoutSeconds, execute: workItem)
  }

  private func emitProgress(
    deviceId: String, phase: String, percent: Int64
  ) {
    // elapsedMs is the time since the pending open started; when nothing is
    // pending (e.g. late catalog updates), fall back to 0 to avoid confusing
    // clients with meaningless negative numbers.
    let base = pendingOpenStartedAt
    let elapsedMs = base == 0
      ? 0
      : Int64((CFAbsoluteTimeGetCurrent() - base) * 1000)
    flutterApi.onSessionOpenProgress(
      deviceId: deviceId,
      phase: phase,
      percent: percent,
      elapsedMs: elapsedMs
    ) { _ in }
  }

  // MARK: - Private helpers

  private func makeInfo(deviceId: String, device: ICCameraDevice)
    -> IccCameraInfo
  {
    return IccCameraInfo(
      deviceId: deviceId,
      name: device.name ?? "Unknown camera",
      transportKind: "usb",
      model: device.name,
      serialNumber: nil,
      isRemote: false
    )
  }

  private func idFor(_ device: ICDevice) -> String {
    return "icc-\(String(UInt(bitPattern: ObjectIdentifier(device).hashValue), radix: 16))"
  }

  private func iccError(code: Int, message: String) -> NSError {
    return NSError(
      domain: "IccPtp",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  /// Build a PTP command container per PIMA 15740 §11.1.2.
  ///
  /// Layout (little-endian):
  ///   [0..3]  ContainerLength — placeholder, ImageCaptureCore rewrites it
  ///   [4..5]  ContainerType = 0x0001 (Command)
  ///   [6..7]  Code = opcode
  ///   [8..11] TransactionID
  ///   [12..]  Params (uint32 each, up to 5)
  private func buildCommandBlock(opcode: Int64, txId: Int64, params: [Int64])
    -> Data
  {
    let totalLen = 12 + params.count * 4
    var data = Data(count: totalLen)
    data.withUnsafeMutableBytes { raw in
      let u32 = raw.bindMemory(to: UInt32.self)
      u32[0] = UInt32(totalLen)
      // Little-endian packing: bytes 4-5 = ContainerType (0x0001),
      // bytes 6-7 = opcode. Writing as one uint32 gives exactly that.
      u32[1] = UInt32(0x0001) | (UInt32(opcode & 0xFFFF) << 16)
      u32[2] = UInt32(truncatingIfNeeded: txId)
      for i in 0..<params.count {
        u32[3 + i] = UInt32(truncatingIfNeeded: params[i])
      }
    }
    return data
  }

  /// Parse a response container. Returns (responseCode, params).
  private func parseResponseBlock(_ block: Data?) -> (UInt16, [Int64]) {
    guard let block = block, block.count >= 12 else {
      return (0x2002, []) // General error
    }
    return block.withUnsafeBytes { raw -> (UInt16, [Int64]) in
      let u16 = raw.bindMemory(to: UInt16.self)
      let u32 = raw.bindMemory(to: UInt32.self)
      let totalLen = Int(u32[0])
      // Layout: [len(4)] [type(2)] [code(2)] [txId(4)] [params...]
      // Offsets in u16: [type(2)] = index 2, [code(2)] = index 3
      let respCode = u16[3]
      let paramCount = max(0, (totalLen - 12) / 4)
      var params: [Int64] = []
      params.reserveCapacity(paramCount)
      for i in 0..<paramCount {
        params.append(Int64(u32[3 + i]))
      }
      return (respCode, params)
    }
  }

  /// Parse an event container. Same layout as command/response.
  /// Returns (eventCode, transactionId, params).
  private func parseEventBlock(_ block: Data) -> (UInt16, UInt32, [Int64]) {
    guard block.count >= 12 else { return (0, 0, []) }
    return block.withUnsafeBytes { raw -> (UInt16, UInt32, [Int64]) in
      let u16 = raw.bindMemory(to: UInt16.self)
      let u32 = raw.bindMemory(to: UInt32.self)
      let totalLen = Int(u32[0])
      let eventCode = u16[3]
      let txId = u32[2]
      let paramCount = max(0, (totalLen - 12) / 4)
      var params: [Int64] = []
      params.reserveCapacity(paramCount)
      for i in 0..<paramCount {
        params.append(Int64(u32[3 + i]))
      }
      return (eventCode, txId, params)
    }
  }

  // MARK: - PTP command callback

  @objc private func didSendPTPCommand(
    _ command: NSData,
    inData: NSData?,
    response: NSData?,
    error: NSError?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    guard let ctx = contextInfo else { return }
    let requestId =
      Unmanaged<NSString>.fromOpaque(ctx).takeRetainedValue() as String
    guard let completion = pendingCommands.removeValue(forKey: requestId)
    else { return }
    let startedAt = pendingCommandStartedAt.removeValue(forKey: requestId)
    let opcode = pendingCommandOpcodes.removeValue(forKey: requestId) ?? 0
    let elapsedMs: Int64 = startedAt.map {
      Int64((CFAbsoluteTimeGetCurrent() - $0) * 1000)
    } ?? -1

    if let error = error {
      log(
        "command.error",
        "opcode=0x\(String(opcode, radix: 16)) elapsedMs=\(elapsedMs) err=\(error.localizedDescription)",
        error: true,
        elapsedMs: elapsedMs
      )
      completion(.failure(error))
      return
    }

    let (respCode, respParams) = parseResponseBlock(response as Data?)
    let inBytes = (inData as Data?) ?? Data()
    log(
      "command.response",
      "opcode=0x\(String(opcode, radix: 16)) respCode=0x\(String(respCode, radix: 16)) elapsedMs=\(elapsedMs) inBytes=\(inBytes.count)",
      elapsedMs: elapsedMs
    )
    let result = PtpCommandResult(
      responseCode: Int64(respCode),
      responseParams: respParams,
      data: inBytes.isEmpty
        ? nil
        : FlutterStandardTypedData(bytes: inBytes)
    )
    completion(.success(result))
  }
}

// MARK: - ICDeviceBrowserDelegate

extension IccDeviceCoordinator: ICDeviceBrowserDelegate {
  func deviceBrowser(
    _ browser: ICDeviceBrowser,
    didAdd device: ICDevice,
    moreComing: Bool
  ) {
    guard let camera = device as? ICCameraDevice else { return }
    let deviceId = idFor(camera)
    log(
      "browser.didAdd",
      "deviceId=\(deviceId) name=\(camera.name ?? "<nil>") moreComing=\(moreComing)"
    )
    devicesById[deviceId] = camera
    let info = makeInfo(deviceId: deviceId, device: camera)
    flutterApi.onDeviceAdded(device: info) { _ in }

    // Eager pre-open: only when Dart-side Discovery is subscribed
    // (`setEagerPreOpen(true)`). Kicks off `requestOpenSession` +
    // warmup PTP in the background so a user tap later hits the fast
    // path.
    if eagerPreOpenEnabled {
      tryStartEagerOpen(deviceId: deviceId, camera: camera)
    }
  }

  func deviceBrowser(
    _ browser: ICDeviceBrowser,
    didRemove device: ICDevice,
    moreGoing: Bool
  ) {
    let deviceId = idFor(device)
    log(
      "browser.didRemove",
      "deviceId=\(deviceId) moreGoing=\(moreGoing)"
    )
    devicesById.removeValue(forKey: deviceId)
    warmupCompletedDeviceIds.remove(deviceId)
    flutterApi.onDeviceRemoved(deviceId: deviceId) { _ in }

    if activeDeviceId == deviceId {
      activeDevice = nil
      activeDeviceId = nil
      pendingOpenWatchdog?.cancel()
      pendingOpenWatchdog = nil
      catalogObserver?.invalidate()
      catalogObserver = nil
      // Fire any waiting completions with an unplug error so callers
      // don't hang forever on a device that's gone.
      if !pendingOpenCompletions.isEmpty {
        let comps = pendingOpenCompletions
        pendingOpenCompletions = []
        pendingOpenDeviceId = nil
        let err = iccError(code: 410,
          message: "Device \(deviceId) unplugged during openSession")
        for c in comps { c(.failure(err)) }
      }
      flutterApi.onSessionEnded(
        deviceId: deviceId, reason: "unplug") { _ in }
    }
  }
}

// MARK: - ICCameraDeviceDelegate (extends ICDeviceDelegate)

extension IccDeviceCoordinator: ICCameraDeviceDelegate {
  // --- ICDeviceDelegate required ---

  func didRemove(_ device: ICDevice) {
    // Belt-and-braces: on iOS, only ONE of `ICDeviceBrowserDelegate.
    // deviceBrowser(_:didRemove:moreGoing:)` and `ICDeviceDelegate.
    // didRemove(_:)` reliably fires when a camera is unplugged mid-session,
    // and which one depends on SDK version. Handle both, idempotently.
    let deviceId = idFor(device)
    log("device.didRemove", "deviceId=\(deviceId)")
    let wasActive = (activeDeviceId == deviceId)
    devicesById.removeValue(forKey: deviceId)
    warmupCompletedDeviceIds.remove(deviceId)
    if wasActive {
      activeDevice = nil
      activeDeviceId = nil
      pendingOpenWatchdog?.cancel()
      pendingOpenWatchdog = nil
      catalogObserver?.invalidate()
      catalogObserver = nil
      if !pendingOpenCompletions.isEmpty {
        let comps = pendingOpenCompletions
        pendingOpenCompletions = []
        pendingOpenDeviceId = nil
        let err = iccError(code: 410,
          message: "Device \(deviceId) unplugged during openSession")
        for c in comps { c(.failure(err)) }
      }
      flutterApi.onSessionEnded(
        deviceId: deviceId, reason: "unplug") { _ in }
    }
    flutterApi.onDeviceRemoved(deviceId: deviceId) { _ in }
  }

  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    let deviceId = pendingOpenDeviceId ?? idFor(device)
    let elapsedMs = Int64(
      (CFAbsoluteTimeGetCurrent() - pendingOpenStartedAt) * 1000)

    pendingOpenWatchdog?.cancel()
    pendingOpenWatchdog = nil

    if pendingOpenCompletions.isEmpty {
      log(
        "openSession.didOpen",
        "without_pending deviceId=\(deviceId) elapsedMs=\(elapsedMs)",
        error: true,
        elapsedMs: elapsedMs
      )
      return
    }

    if let error = error {
      log(
        "openSession.didOpen",
        "err deviceId=\(deviceId) elapsedMs=\(elapsedMs) err=\(error.localizedDescription)",
        error: true,
        elapsedMs: elapsedMs
      )
      let comps = pendingOpenCompletions
      pendingOpenCompletions = []
      pendingOpenDeviceId = nil
      catalogObserver?.invalidate()
      catalogObserver = nil
      activeDevice = nil
      activeDeviceId = nil
      for c in comps { c(.failure(error)) }
      return
    }

    // Success: fire warmup PTP GetDeviceInfo BEFORE releasing the
    // pending completions. That way, when the pigeon completion resolves
    // on the Dart side, Apple's ICA has already paid its ~80 s internal
    // first-command tax and Dart's own PTP commands land on a warm session.
    // If a user tap arrives during warmup, they attach to
    // `pendingOpenCompletions` (see openSession above) and fire together.
    log(
      "openSession.didOpen",
      "ok deviceId=\(deviceId) elapsedMs=\(elapsedMs), starting warmup",
      elapsedMs: elapsedMs
    )
    emitProgress(deviceId: deviceId, phase: "ready", percent: 100)
    guard let camera = device as? ICCameraDevice else {
      // Defensive — device delegate wired only on ICCameraDevice, but if
      // we ever get here without a camera, skip warmup and fire success.
      let comps = pendingOpenCompletions
      pendingOpenCompletions = []
      pendingOpenDeviceId = nil
      for c in comps { c(.success(true)) }
      return
    }
    fireWarmup(deviceId: deviceId, camera: camera)
  }

  /// Fire the warmup `GetDeviceInfo` PTP command so Apple's ICA
  /// internal enumeration runs in the background before Dart sees a
  /// session-ready callback. Marks `warmupCompletedDeviceIds` and
  /// releases all `pendingOpenCompletions` on completion (success or
  /// failure — the session IS open regardless, and Dart's own commands
  /// will surface their own errors).
  private func fireWarmup(deviceId: String, camera: ICCameraDevice) {
    guard !warmupInProgress else { return }
    warmupInProgress = true
    let warmupStart = CFAbsoluteTimeGetCurrent()
    log("warmup.start",
      "sending GetDeviceInfo (tx=1) to pay ICA first-PTP tax deviceId=\(deviceId)")
    sendRawPTP(
      camera: camera,
      opcode: 0x1001, // GetDeviceInfo
      txId: 1,
      params: [],
      outData: nil
    ) { [weak self] result in
      guard let self = self else { return }
      self.warmupInProgress = false
      let elapsedMs = Int64(
        (CFAbsoluteTimeGetCurrent() - warmupStart) * 1000)
      switch result {
      case .success(let r):
        self.log(
          "warmup.done",
          "ok elapsedMs=\(elapsedMs) respCode=0x\(String(r.responseCode, radix: 16))",
          elapsedMs: elapsedMs
        )
      case .failure(let e):
        self.log(
          "warmup.done",
          "err elapsedMs=\(elapsedMs) err=\(e.localizedDescription)",
          error: true,
          elapsedMs: elapsedMs
        )
      }
      self.warmupCompletedDeviceIds.insert(deviceId)
      let comps = self.pendingOpenCompletions
      self.pendingOpenCompletions = []
      self.pendingOpenDeviceId = nil
      for c in comps { c(.success(true)) }
    }
  }

  /// Extracted PTP command send path — shared between user-visible
  /// `sendPtpCommand(...)` and the internal warmup.
  private func sendRawPTP(
    camera: ICCameraDevice,
    opcode: Int64,
    txId: Int64,
    params: [Int64],
    outData: Data?,
    completion: @escaping (Result<PtpCommandResult, Error>) -> Void
  ) {
    let cmdBlock = buildCommandBlock(
      opcode: opcode, txId: txId, params: params)
    let requestId = UUID().uuidString
    pendingCommands[requestId] = completion
    pendingCommandStartedAt[requestId] = CFAbsoluteTimeGetCurrent()
    pendingCommandOpcodes[requestId] = opcode
    let ctx = Unmanaged.passRetained(requestId as NSString).toOpaque()
    log("command.request",
      "opcode=0x\(String(opcode, radix: 16)) tx=\(txId)")
    camera.requestSendPTPCommand(
      cmdBlock,
      outData: outData,
      sendCommandDelegate: self,
      didSendCommand: #selector(
        didSendPTPCommand(_:inData:response:error:contextInfo:)),
      contextInfo: ctx
    )
  }

  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    let elapsedMs = Int64(
      (CFAbsoluteTimeGetCurrent() - pendingCloseStartedAt) * 1000)
    guard let completion = pendingCloseCompletion else {
      log(
        "closeSession.didClose",
        "without_pending elapsedMs=\(elapsedMs)",
        error: true,
        elapsedMs: elapsedMs
      )
      return
    }
    pendingCloseCompletion = nil
    catalogObserver?.invalidate()
    catalogObserver = nil
    if let closedId = activeDeviceId {
      // Session is gone → warmup would have to re-run next open.
      warmupCompletedDeviceIds.remove(closedId)
    }
    activeDevice = nil
    activeDeviceId = nil
    if let error = error {
      log(
        "closeSession.didClose",
        "err elapsedMs=\(elapsedMs) err=\(error.localizedDescription)",
        error: true,
        elapsedMs: elapsedMs
      )
      completion(.failure(error))
    } else {
      log(
        "closeSession.didClose",
        "ok elapsedMs=\(elapsedMs)",
        elapsedMs: elapsedMs
      )
      completion(.success(()))
    }
  }

  // --- ICDeviceDelegate optional but declared required in Swift bridge ---

  func device(_ device: ICDevice, didEncounterError error: Error?) {
    // Non-fatal error notification — we surface fatal ones via
    // pendingOpen/CloseCompletion + PTP responseCode.
    log(
      "device.didEncounterError",
      "err=\(error?.localizedDescription ?? "<nil>")",
      error: true
    )
  }

  // --- ICCameraDeviceDelegate: PTP event push (the reason we're here) ---

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceivePTPEvent eventData: Data
  ) {
    let (code, txId, params) = parseEventBlock(eventData)
    log(
      "ptpEvent",
      "code=0x\(String(code, radix: 16)) tx=\(txId)"
    )
    flutterApi.onPtpEvent(
      eventCode: Int64(code),
      transactionId: Int64(txId),
      params: params
    ) { _ in }
  }

  // --- ICCameraDeviceDelegate: other required methods (no-op stubs) ---
  //
  // ImageCaptureCore's Swift bridge treats several nominally-optional
  // methods as required (Xcode's Fix-It auto-inserts them). We control
  // the camera through raw PTP over `requestSendPTPCommand`, so the
  // media-catalog callbacks below carry no information we act on.

  func cameraDevice(
    _ camera: ICCameraDevice,
    didAdd items: [ICCameraItem]
  ) {}

  func cameraDevice(
    _ camera: ICCameraDevice,
    didRemove items: [ICCameraItem]
  ) {}

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceiveThumbnail thumbnail: CGImage?,
    for item: ICCameraItem,
    error: Error?
  ) {}

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem,
    error: Error?
  ) {}

  func cameraDevice(
    _ camera: ICCameraDevice,
    didRenameItems items: [ICCameraItem]
  ) {}

  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice)
  {
    // Not consumed by the session-open flow (`didOpenSessionWithError` is our
    // ready signal), but hugely useful for diagnosing "why did openSession
    // take 3 minutes" — this delegate fires once ICA has finished indexing.
    let elapsedMs = pendingOpenStartedAt == 0
      ? Int64(-1)
      : Int64((CFAbsoluteTimeGetCurrent() - pendingOpenStartedAt) * 1000)
    let deviceId = activeDeviceId ?? idFor(device)
    log(
      "catalog.ready",
      "deviceId=\(deviceId) elapsedMs=\(elapsedMs)",
      elapsedMs: elapsedMs
    )
  }

  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
    log("device.accessRestriction", "removed")
  }

  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
    log("device.accessRestriction", "enabled")
  }
}
