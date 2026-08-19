import 'dart:async';
import 'dart:typed_data';

import '../codec/byte_writer.dart';
import '../codec/live_view_frame_codec.dart';
import '../codec/ptp_data_codec.dart';
import '../constants/nikon_opcodes.dart';
import '../constants/response_codes.dart';
import '../constants/standard_opcodes.dart';
import '../errors/ptp_errors.dart';
import '../model/camera_event.dart';
import '../model/device_info.dart';
import '../model/device_prop_desc.dart';
import '../model/live_view_frame.dart';
import '../model/nikon_z_model.dart';
import '../model/object_info.dart';
import '../model/ptp_transaction.dart';
import '../model/storage_info.dart';
import '../session/operation_queue.dart';
import '../session/ptp_session.dart';
import '../transport/cancel_token.dart';

/// High-level Nikon Z-series camera API.
///
/// Wraps [PtpSession] with the domain-specific semantics of PTP + the
/// Nikon vendor extension: application-mode entry, structured event
/// polling, live view control, property get/set, and chunked object
/// downloads.
final class NikonZClient {
  NikonZClient(this.session);

  final PtpSession session;

  DeviceInfo? _deviceInfo;
  NikonZQuirks? _quirks;

  DeviceInfo? get deviceInfo => _deviceInfo;
  NikonZQuirks? get quirks => _quirks;

  Stream<CameraEvent> get events => session.events;

  // ─── lifecycle ──────────────────────────────────────────────────

  /// Open the PTP session, enumerate the device, and (on Z bodies)
  /// enter controller application mode. Idempotent.
  ///
  /// If ChangeApplicationMode returns AccessDenied / NotSupported we log
  /// the fact via [changeApplicationModeSkipped] but do NOT abort — read
  /// paths (GetDeviceInfo, storage/object enumeration, thumbnails) work
  /// fine without controller mode. Only remote-control ops (capture,
  /// property writes, Live View start) will fail later, and the caller
  /// can surface a targeted error at that point.
  bool changeApplicationModeSkipped = false;
  int? changeApplicationModeErrorCode;

  /// [onPhase] is fired at each connect sub-step transition so the UI can
  /// render per-step timing. [phase] is one of:
  /// `sessionOpen.start` / `sessionOpen.done` /
  /// `getDeviceInfo.start` / `getDeviceInfo.done` /
  /// `changeApplicationMode.start` / `changeApplicationMode.done` /
  /// `changeApplicationMode.skipped` /
  /// `waitDeviceReady.start` / `waitDeviceReady.done`.
  /// [elapsedMsSinceConnect] is measured from the start of [connect].
  Future<DeviceInfo> connect({
    void Function(String phase, int elapsedMsSinceConnect)? onPhase,
  }) async {
    final sw = Stopwatch()..start();
    void phase(String name) => onPhase?.call(name, sw.elapsedMilliseconds);

    phase('sessionOpen.start');
    await session.open();
    phase('sessionOpen.done');

    phase('getDeviceInfo.start');
    final info = await getDeviceInfo();
    phase('getDeviceInfo.done');
    _deviceInfo = info;

    final model = NikonZModel.fromModelString(info.model);
    _quirks = NikonZQuirks.defaults(model, info.deviceVersion);

    if (_quirks!.needsChangeApplicationMode &&
        info.supportsOperation(NikonOpcode.changeApplicationMode)) {
      try {
        phase('changeApplicationMode.start');
        await _changeApplicationMode(1);
        phase('changeApplicationMode.done');
        phase('waitDeviceReady.start');
        await _waitDeviceReady();
        phase('waitDeviceReady.done');
      } on PtpResponseException catch (e) {
        // These non-fatal codes mean "you're not allowed to elevate to
        // controller mode" — usually because the camera is in a
        // non-controller USB mode (pure MTP), or a stale session left
        // over from a previous connection is still holding the role.
        // Log and continue; read paths still work.
        final tolerable = <int>{
          PtpResponseCode.accessDenied,
          PtpResponseCode.operationNotSupported,
          PtpResponseCode.deviceBusy,
          PtpResponseCode.nikonChangeCameraModeFailed,
          PtpResponseCode.nikonInvalidStatus,
        };
        if (tolerable.contains(e.code)) {
          changeApplicationModeSkipped = true;
          changeApplicationModeErrorCode = e.code;
          phase('changeApplicationMode.skipped');
        } else {
          rethrow;
        }
      }
    }

    return info;
  }

  Future<void> disconnect({bool sendCloseSession = true}) =>
      session.close(sendCloseSession: sendCloseSession);

  // ─── enumeration ────────────────────────────────────────────────

  Future<DeviceInfo> getDeviceInfo() async {
    final r = await session.execute(
      const PtpTransaction(
        opcode: StandardOpcode.getDeviceInfo,
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, StandardOpcode.getDeviceInfo);
    return PtpDataCodec.readDeviceInfo(r.data ?? Uint8List(0));
  }

  Future<List<int>> getStorageIds() async {
    final r = await session.execute(
      const PtpTransaction(
        opcode: StandardOpcode.getStorageIds,
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, StandardOpcode.getStorageIds);
    if (r.data == null || r.data!.isEmpty) return const <int>[];
    // Response is a uint32 array (see ISO 15740).
    final view = ByteData.sublistView(r.data!);
    final count = view.getUint32(0, Endian.little);
    return List<int>.generate(
      count,
      (i) => view.getUint32(4 + i * 4, Endian.little),
    );
  }

  Future<StorageInfo> getStorageInfo(int storageId) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: StandardOpcode.getStorageInfo,
        params: [storageId],
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, StandardOpcode.getStorageInfo);
    return PtpDataCodec.readStorageInfo(storageId, r.data ?? Uint8List(0));
  }

  Future<List<int>> getObjectHandles(
    int storageId, {
    int format = 0,
    int parent = 0,
  }) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: StandardOpcode.getObjectHandles,
        params: [storageId, format, parent],
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.normal,
    );
    _throwIfNotOk(r.code, StandardOpcode.getObjectHandles);
    if (r.data == null || r.data!.isEmpty) return const <int>[];
    final view = ByteData.sublistView(r.data!);
    final count = view.getUint32(0, Endian.little);
    return List<int>.generate(
      count,
      (i) => view.getUint32(4 + i * 4, Endian.little),
    );
  }

  Future<ObjectInfo> getObjectInfo(int handle) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: StandardOpcode.getObjectInfo,
        params: [handle],
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.normal,
    );
    _throwIfNotOk(r.code, StandardOpcode.getObjectInfo);
    return PtpDataCodec.readObjectInfo(r.data ?? Uint8List(0));
  }

  Future<Uint8List> getThumbnail(int handle) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: StandardOpcode.getThumb,
        params: [handle],
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.low,
    );
    if (r.code == PtpResponseCode.noThumbnailPresent) return Uint8List(0);
    _throwIfNotOk(r.code, StandardOpcode.getThumb);
    return r.data ?? Uint8List(0);
  }

  // ─── properties ─────────────────────────────────────────────────

  Future<DevicePropDesc> getPropertyDesc(int propCode) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: StandardOpcode.getDevicePropDesc,
        params: [propCode],
        dataPhase: PtpDataPhase.dataIn,
      ),
      priority: OpPriority.normal,
    );
    _throwIfNotOk(r.code, StandardOpcode.getDevicePropDesc);
    return PtpDataCodec.readDevicePropDesc(r.data ?? Uint8List(0));
  }

  Future<void> setProperty(int propCode, int dataType, Object value) async {
    final payload = PtpDataCodec.writeTypedValue(dataType, value);
    final r = await session.execute(
      PtpTransaction(
        opcode: StandardOpcode.setDevicePropValue,
        params: [propCode],
        dataOut: payload,
        dataPhase: PtpDataPhase.dataOut,
      ),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, StandardOpcode.setDevicePropValue);
    await _waitDeviceReady();
  }

  // ─── capture ────────────────────────────────────────────────────

  /// Nikon "capture to card" — the mainstream shutter release for Z.
  Future<void> capture({int storageId = 0xFFFFFFFF, int format = 0}) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: NikonOpcode.initiateCaptureRecInMedia,
        params: [storageId, format],
      ),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, NikonOpcode.initiateCaptureRecInMedia);
    await _waitDeviceReady();
  }

  Future<void> startMovieRecording() async {
    final r = await session.execute(
      const PtpTransaction(opcode: NikonOpcode.startMovieRecInCard),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, NikonOpcode.startMovieRecInCard);
  }

  Future<void> stopMovieRecording() async {
    final r = await session.execute(
      const PtpTransaction(opcode: NikonOpcode.endMovieRec),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, NikonOpcode.endMovieRec);
  }

  // ─── live view ──────────────────────────────────────────────────

  Future<void> startLiveView() async {
    final r = await session.execute(
      const PtpTransaction(opcode: NikonOpcode.startLiveView),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, NikonOpcode.startLiveView);
    await _waitDeviceReady();
  }

  Future<void> stopLiveView() async {
    final r = await session.execute(
      const PtpTransaction(opcode: NikonOpcode.endLiveView),
      priority: OpPriority.high,
    );
    _throwIfNotOk(r.code, NikonOpcode.endLiveView);
  }

  /// Move the AF area to LV-pixel coordinates ([x], [y]) and (optionally)
  /// drive AF at that location. The default is "aim + drive" — the
  /// idiomatic tap-to-focus flow.
  ///
  /// Coordinates are in the LV frame's pixel space, not screen pixels.
  /// Callers should scale their tap position by (frameWidth / widgetWidth)
  /// before calling.
  Future<void> tapToFocus(
    int x,
    int y, {
    bool drive = true,
  }) async {
    final aim = await session.execute(
      PtpTransaction(
        opcode: NikonOpcode.changeAfArea,
        params: [x, y],
      ),
      priority: OpPriority.high,
    );
    _throwIfNotOk(aim.code, NikonOpcode.changeAfArea);

    if (!drive) return;

    final af = await session.execute(
      const PtpTransaction(opcode: NikonOpcode.afDrive),
      priority: OpPriority.high,
    );
    // AF-not-locked is not the transport's problem — surface it so the UI
    // can flash the AF box red, but only if the camera reported a real
    // failure, not the harmless "already locked" from a rapid re-tap.
    if (af.code == PtpResponseCode.nikonOutOfFocus) return;
    _throwIfNotOk(af.code, NikonOpcode.afDrive);
  }

  /// One-shot Live View frame — raw wire bytes.
  ///
  /// Higher layers decode the ~384-byte Nikon header + JPEG into a
  /// [LiveViewFrame]; this level just gives you the transaction payload.
  Future<Uint8List> getLiveViewFrame() async {
    final useLegacy = _quirks?.useLegacyLiveViewOpcode ?? false;
    final opcode = useLegacy
        ? NikonOpcode.getLiveViewImg
        : NikonOpcode.getLiveViewImageEx;
    final r = await session.execute(
      PtpTransaction(opcode: opcode, dataPhase: PtpDataPhase.dataIn),
      priority: OpPriority.low,
    );
    _throwIfNotOk(r.code, opcode);
    return r.data ?? Uint8List(0);
  }

  /// Convenience wrapper — fetches one raw Live View blob and decodes it
  /// into a [LiveViewFrame]. Returns `null` when the camera answered with
  /// an empty / header-only payload (LV enabled but no frame yet).
  ///
  /// Any [PtpResponseException] from the underlying call propagates
  /// unchanged so higher layers can distinguish transport-level failures
  /// from "camera is warming up".
  Future<LiveViewFrame?> getLiveViewFrameDecoded() async {
    final bytes = await getLiveViewFrame();
    if (bytes.isEmpty) return null;
    return LiveViewFrameCodec.decode(bytes);
  }

  // ─── event polling ──────────────────────────────────────────────

  /// Poll the event queue via the vendor GetEventEx path. Preferred over
  /// waiting for async events on Wi-Fi because the socket may drop them.
  Future<List<CameraEvent>> pollEvents() async {
    final opcode = (_deviceInfo?.supportsOperation(NikonOpcode.getEventEx) ??
            false)
        ? NikonOpcode.getEventEx
        : NikonOpcode.getEvent;
    final r = await session.execute(
      PtpTransaction(opcode: opcode, dataPhase: PtpDataPhase.dataIn),
      priority: OpPriority.normal,
    );
    _throwIfNotOk(r.code, opcode);
    return _parseEvents(r.data ?? Uint8List(0), extended: opcode == NikonOpcode.getEventEx);
  }

  // ─── chunked object download ────────────────────────────────────

  /// Download one object in fixed-size chunks. Emits raw bytes; consumers
  /// can pipe into a file sink or hash accumulator.
  ///
  /// [chunkSize] defaults to 1 MiB — a reasonable balance between
  /// throughput and cancel latency on Wi-Fi.
  Stream<Uint8List> downloadObject(
    int handle,
    int totalSize, {
    int chunkSize = 1024 * 1024,
    CancelToken? cancelToken,
  }) async* {
    final use64 = totalSize >= 0xFFFFFFFF ||
        (_deviceInfo?.supportsOperation(NikonOpcode.getPartialObjectEx) ??
            false);

    var offset = 0;
    while (offset < totalSize) {
      cancelToken?.throwIfCancelled();
      final want = (offset + chunkSize <= totalSize)
          ? chunkSize
          : totalSize - offset;

      final tx = use64
          ? PtpTransaction(
              opcode: NikonOpcode.getPartialObjectEx,
              params: [
                handle,
                offset & 0xFFFFFFFF,
                (offset >> 32) & 0xFFFFFFFF,
                want,
                0,
              ],
              dataPhase: PtpDataPhase.dataIn,
            )
          : PtpTransaction(
              opcode: StandardOpcode.getPartialObject,
              params: [handle, offset, want],
              dataPhase: PtpDataPhase.dataIn,
            );

      final r = await session.execute(
        tx,
        priority: OpPriority.background,
        cancelToken: cancelToken,
      );
      _throwIfNotOk(r.code, tx.opcode);

      final chunk = r.data ?? Uint8List(0);
      if (chunk.isEmpty) break;
      yield chunk;
      offset += chunk.length;
    }
  }

  // ─── internals ──────────────────────────────────────────────────

  Future<void> _changeApplicationMode(int mode) async {
    final r = await session.execute(
      PtpTransaction(
        opcode: NikonOpcode.changeApplicationMode,
        params: [mode, 0],
      ),
      priority: OpPriority.critical,
    );
    _throwIfNotOk(r.code, NikonOpcode.changeApplicationMode);
  }

  /// Poll DeviceReady until the camera stops returning DeviceBusy.
  Future<void> _waitDeviceReady({
    Duration pollInterval = const Duration(milliseconds: 50),
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.timestamp().add(timeout);
    while (true) {
      final r = await session.execute(
        const PtpTransaction(opcode: NikonOpcode.deviceReady),
        priority: OpPriority.normal,
      );
      if (r.code == PtpResponseCode.ok) return;
      if (r.code != PtpResponseCode.deviceBusy) {
        // Some firmware returns OperationNotSupported for DeviceReady; treat
        // as "camera doesn't gate on this, proceed."
        if (r.code == PtpResponseCode.operationNotSupported) return;
        throw PtpResponseException(
          r.code,
          opcode: NikonOpcode.deviceReady,
          context: 'DeviceReady poll',
        );
      }
      if (DateTime.timestamp().isAfter(deadline)) {
        throw const PtpTimeoutException('DeviceReady poll timed out');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  List<CameraEvent> _parseEvents(Uint8List data, {required bool extended}) {
    if (data.isEmpty) return const <CameraEvent>[];
    final view = ByteData.sublistView(data);
    final count = view.getUint16(0, Endian.little);
    final out = <CameraEvent>[];
    // Legacy event record: uint16 eventCode + uint32 param
    // Extended (GetEventEx) event record: uint16 eventCode + uint32 param +
    //   uint32 transactionId + uint16 dataSize (per libgphoto2 ptp2/ptp.c).
    var offset = 2;
    for (var i = 0; i < count; i++) {
      if (offset + 6 > data.length) break;
      final code = view.getUint16(offset, Endian.little);
      offset += 2;
      final p1 = view.getUint32(offset, Endian.little);
      offset += 4;
      var tx = 0;
      var p2 = 0;
      if (extended && offset + 4 <= data.length) {
        tx = view.getUint32(offset, Endian.little);
        offset += 4;
        if (offset + 2 <= data.length) {
          p2 = view.getUint16(offset, Endian.little);
          offset += 2;
        }
      }
      out.add(CameraEvent(code: code, transactionId: tx, p1: p1, p2: p2));
    }
    return out;
  }

  void _throwIfNotOk(int code, int opcode) {
    if (PtpResponseCode.isOk(code)) return;
    throw PtpResponseException(code, opcode: opcode);
  }
}
