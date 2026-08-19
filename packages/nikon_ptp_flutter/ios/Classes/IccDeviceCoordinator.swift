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
  // completion here until didOpenSessionWithError / didCloseSessionWithError
  // fires. Guarded implicitly by ICA serialising these delegate calls.
  private var pendingOpenCompletion: ((Result<Bool, Error>) -> Void)?
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

  // The openSession watchdog. Kept as an instance constant so tests could
  // override it — currently only used by the default 120 s deadline.
  private let openSessionTimeoutSeconds: Double = 120.0

  init(flutterApi: IccPtpFlutterApi) {
    self.flutterApi = flutterApi
    self.browser = ICDeviceBrowser()
    super.init()

    log("browser.init", "coordinator constructed")
    self.browser.delegate = self
    let mask = ICDeviceTypeMask(rawValue:
      ICDeviceTypeMask.camera.rawValue |
      ICDeviceLocationTypeMask.local.rawValue
    )
    if let mask = mask {
      self.browser.browsedDeviceTypeMask = mask
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
    if camera.hasOpenSession {
      log(
        "openSession.fastpath",
        "deviceId=\(deviceId) reason=already_open"
      )
      activeDevice = camera
      activeDeviceId = deviceId
      completion(.success(true))
      return
    }
    if pendingOpenCompletion != nil {
      log(
        "openSession.reject",
        "deviceId=\(deviceId) reason=another_in_progress",
        error: true
      )
      completion(.failure(iccError(code: 409,
        message: "Another openSession is in progress")))
      return
    }
    activeDevice = camera
    activeDeviceId = deviceId
    pendingOpenCompletion = completion
    pendingOpenDeviceId = deviceId
    pendingOpenStartedAt = CFAbsoluteTimeGetCurrent()
    camera.delegate = self

    installCatalogObserver(on: camera, deviceId: deviceId)
    emitProgress(deviceId: deviceId, phase: "openSession", percent: -1)
    schedulePendingOpenWatchdog(deviceId: deviceId)

    log(
      "openSession.requestOpenSession",
      "issued deviceId=\(deviceId)"
    )
    camera.requestOpenSession()
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
    let cmdBlock = buildCommandBlock(
      opcode: opcode, txId: txId, params: params)

    // Retained NSString round-trips through ICA's opaque contextInfo pointer.
    let requestId = UUID().uuidString
    pendingCommands[requestId] = completion
    pendingCommandStartedAt[requestId] = CFAbsoluteTimeGetCurrent()
    pendingCommandOpcodes[requestId] = opcode
    let ctx = Unmanaged.passRetained(requestId as NSString).toOpaque()

    log(
      "command.request",
      "opcode=0x\(String(opcode, radix: 16)) tx=\(txId)"
    )
    camera.requestSendPTPCommand(
      cmdBlock,
      outData: outData,
      sendCommandDelegate: self,
      didSendCommand: #selector(
        didSendPTPCommand(_:inData:response:error:contextInfo:)),
      contextInfo: ctx
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
      guard let completion = self.pendingOpenCompletion else { return }
      let elapsedMs = Int64(
        (CFAbsoluteTimeGetCurrent() - self.pendingOpenStartedAt) * 1000)
      self.log(
        "openSession.timeout",
        "deviceId=\(deviceId) elapsedMs=\(elapsedMs)",
        error: true,
        elapsedMs: elapsedMs
      )
      self.pendingOpenCompletion = nil
      self.pendingOpenDeviceId = nil
      self.catalogObserver?.invalidate()
      self.catalogObserver = nil
      self.activeDevice = nil
      self.activeDeviceId = nil
      self.emitProgress(deviceId: deviceId, phase: "timeout", percent: -1)
      self.flutterApi.onSessionEnded(
        deviceId: deviceId, reason: "timeout") { _ in }
      completion(.failure(self.iccError(
        code: 504,
        message:
          "ICA openSession timeout after \(Int(self.openSessionTimeoutSeconds))s")))
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
    flutterApi.onDeviceRemoved(deviceId: deviceId) { _ in }

    if activeDeviceId == deviceId {
      activeDevice = nil
      activeDeviceId = nil
      pendingOpenWatchdog?.cancel()
      pendingOpenWatchdog = nil
      catalogObserver?.invalidate()
      catalogObserver = nil
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
    if wasActive {
      activeDevice = nil
      activeDeviceId = nil
      pendingOpenWatchdog?.cancel()
      pendingOpenWatchdog = nil
      catalogObserver?.invalidate()
      catalogObserver = nil
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

    guard let completion = pendingOpenCompletion else {
      log(
        "openSession.didOpen",
        "without_pending deviceId=\(deviceId) elapsedMs=\(elapsedMs)",
        error: true,
        elapsedMs: elapsedMs
      )
      return
    }
    pendingOpenCompletion = nil
    pendingOpenDeviceId = nil

    if let error = error {
      log(
        "openSession.didOpen",
        "err deviceId=\(deviceId) elapsedMs=\(elapsedMs) err=\(error.localizedDescription)",
        error: true,
        elapsedMs: elapsedMs
      )
      catalogObserver?.invalidate()
      catalogObserver = nil
      activeDevice = nil
      activeDeviceId = nil
      completion(.failure(error))
    } else {
      log(
        "openSession.didOpen",
        "ok deviceId=\(deviceId) elapsedMs=\(elapsedMs)",
        elapsedMs: elapsedMs
      )
      emitProgress(deviceId: deviceId, phase: "ready", percent: 100)
      // Keep the catalog observer alive after ready — camera-side indexing
      // can continue and downstream clients (e.g. gallery) may still care.
      completion(.success(true))
    }
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
