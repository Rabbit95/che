import Foundation
import Flutter
import ImageCaptureCore

/// Owns the `ICDeviceBrowser` and the currently-active `ICCameraDevice`
/// session. Phase B wired discovery; Phase C wires session lifecycle +
/// PTP command marshalling via the selector-based ICA callback API.
final class IccDeviceCoordinator: NSObject {
  private let flutterApi: IccPtpFlutterApi
  private let browser: ICDeviceBrowser
  private var devicesById: [String: ICCameraDevice] = [:]

  // Active session state — at most one camera has an open session at a time.
  private var activeDevice: ICCameraDevice?
  private var activeDeviceId: String?

  // Session open/close are ICA delegate callbacks, so we stash the pigeon
  // completion here until didOpenSessionWithError / didCloseSessionWithError
  // fires. Guarded implicitly by ICA serialising these delegate calls.
  private var pendingOpenCompletion: ((Result<Bool, Error>) -> Void)?
  private var pendingCloseCompletion: ((Result<Void, Error>) -> Void)?

  // PTP command completions keyed by a synthetic requestId which we round-trip
  // through ICA's opaque `contextInfo` pointer.
  private var pendingCommands:
    [String: (Result<PtpCommandResult, Error>) -> Void] = [:]

  init(flutterApi: IccPtpFlutterApi) {
    self.flutterApi = flutterApi
    self.browser = ICDeviceBrowser()
    super.init()

    self.browser.delegate = self
    let mask = ICDeviceTypeMask(rawValue:
      ICDeviceTypeMask.camera.rawValue |
      ICDeviceLocationTypeMask.local.rawValue
    )
    if let mask = mask {
      self.browser.browsedDeviceTypeMask = mask
    }
    self.browser.start()
  }

  deinit {
    browser.stop()
  }

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
    guard let camera = devicesById[deviceId] else {
      completion(.failure(iccError(code: 404,
        message: "Device \(deviceId) not in browser cache")))
      return
    }
    if camera.hasOpenSession {
      activeDevice = camera
      activeDeviceId = deviceId
      completion(.success(true))
      return
    }
    if pendingOpenCompletion != nil {
      completion(.failure(iccError(code: 409,
        message: "Another openSession is in progress")))
      return
    }
    activeDevice = camera
    activeDeviceId = deviceId
    pendingOpenCompletion = completion
    camera.delegate = self
    camera.requestOpenSession()
  }

  func closeSession(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let camera = activeDevice else {
      completion(.success(()))
      return
    }
    if !camera.hasOpenSession {
      activeDevice = nil
      activeDeviceId = nil
      completion(.success(()))
      return
    }
    if pendingCloseCompletion != nil {
      completion(.failure(iccError(code: 409,
        message: "Another closeSession is in progress")))
      return
    }
    pendingCloseCompletion = completion
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
      completion(.failure(iccError(code: 400,
        message: "No open ICA session — call openSession first")))
      return
    }
    let cmdBlock = buildCommandBlock(
      opcode: opcode, txId: txId, params: params)

    // Retained NSString round-trips through ICA's opaque contextInfo pointer.
    let requestId = UUID().uuidString
    pendingCommands[requestId] = completion
    let ctx = Unmanaged.passRetained(requestId as NSString).toOpaque()

    camera.requestSendPTPCommand(
      cmdBlock,
      outData: outData,
      sendCommandDelegate: self,
      didSendCommand: #selector(
        didSendPTPCommand(_:inData:response:error:contextInfo:)),
      contextInfo: ctx
    )
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

    if let error = error {
      completion(.failure(error))
      return
    }

    let (respCode, respParams) = parseResponseBlock(response as Data?)
    let inBytes = (inData as Data?) ?? Data()
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
    devicesById.removeValue(forKey: deviceId)
    flutterApi.onDeviceRemoved(deviceId: deviceId) { _ in }

    if activeDeviceId == deviceId {
      activeDevice = nil
      activeDeviceId = nil
      flutterApi.onSessionEnded(
        deviceId: deviceId, reason: "unplug") { _ in }
    }
  }
}

// MARK: - ICDeviceDelegate (required)

extension IccDeviceCoordinator: ICDeviceDelegate {
  func didRemove(_ device: ICDevice) {
    // Browser delegate already handles cache eviction + session cleanup.
    // Nothing to do here beyond satisfying the protocol requirement.
  }

  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    guard let completion = pendingOpenCompletion else { return }
    pendingOpenCompletion = nil
    if let error = error {
      activeDevice = nil
      activeDeviceId = nil
      completion(.failure(error))
    } else {
      completion(.success(true))
    }
  }

  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    guard let completion = pendingCloseCompletion else { return }
    pendingCloseCompletion = nil
    activeDevice = nil
    activeDeviceId = nil
    if let error = error {
      completion(.failure(error))
    } else {
      completion(.success(()))
    }
  }
}
