import 'dart:async';
import 'dart:typed_data';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:quick_usb/quick_usb.dart';

import 'nikon_usb_ids.dart';

/// PTP-USB (USB Still Image class) transport for Android / Windows /
/// macOS / Linux.
///
/// Uses `quick_usb` for the bulk endpoints. Interrupt endpoint reads are
/// not exposed by quick_usb yet, so async events are polled via
/// `NikonZClient.pollEvents` (which uses GetEventEx / GetEvent under the
/// hood). This keeps the transport simple and portable — good enough for
/// the "controls + LV + downloads" use cases; if we ever need push events
/// on USB we can add a platform-specific interrupt reader later.
///
/// Only one PTP session may be open across the whole app at a time — a
/// PTP session is stateful and PTP-USB has no multiplexing.
final class UsbTransport implements Transport {
  UsbTransport({UsbDevice? preSelectedDevice}) : _preSelected = preSelectedDevice;

  final UsbDevice? _preSelected;

  UsbDevice? _device;
  UsbInterface? _interface;
  UsbEndpoint? _bulkIn;
  UsbEndpoint? _bulkOut;

  int _transactionId = 0;
  int _readBufferSize = 16 * 1024;

  final StreamController<CameraEvent> _events =
      StreamController<CameraEvent>.broadcast();
  final StreamController<TransportState> _states =
      StreamController<TransportState>.broadcast();

  TransportState _state = TransportState.idle;

  static bool _initialised = false;
  static Future<void> _ensureInit() async {
    if (_initialised) return;
    await QuickUsb.init();
    _initialised = true;
  }

  @override
  TransportChannel get channel => TransportChannel.usb;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateChanges => _states.stream;

  @override
  Stream<CameraEvent> get events => _events.stream;

  @override
  Future<void> open(TransportConfig config) async {
    if (config.channel != TransportChannel.usb) {
      throw ArgumentError.value(
        config.channel,
        'config.channel',
        'UsbTransport requires channel=usb',
      );
    }
    _setState(TransportState.connecting);
    try {
      await _ensureInit();

      final device = _preSelected ?? await _findNikonDevice(config.usbSerial);
      if (device == null) {
        throw const PtpTransportException(
          '未找到已连接的 Nikon 相机 (USB 模式请设为 MTP/PTP)',
        );
      }
      _device = device;

      final hasPerm = await QuickUsb.hasPermission(device);
      if (!hasPerm) {
        final granted = await QuickUsb.requestPermission(device);
        if (!granted) {
          throw const PtpTransportException('USB 权限被拒绝');
        }
      }

      final opened = await QuickUsb.openDevice(device);
      if (!opened) {
        throw const PtpTransportException('打开 USB 设备失败');
      }

      final (iface, bulkIn, bulkOut) = await _claimStillImageInterface();
      _interface = iface;
      _bulkIn = bulkIn;
      _bulkOut = bulkOut;

      // A previous session that crashed before releasing the interface
      // can leave one or both bulk endpoints in a halted state — the
      // camera will then reject the very first data packet until we
      // send CLEAR_FEATURE(ENDPOINT_HALT). Best-effort: we swallow the
      // return value and any transport exception here because on desktop
      // (libusb) this is a no-op and on Android it just fails fast if
      // the endpoint isn't actually halted.
      try {
        await QuickUsb.clearHalt(bulkIn);
        await QuickUsb.clearHalt(bulkOut);
      } on Object {
        // Not fatal — if the endpoints weren't halted this returns false
        // or throws PlatformException on some devices; in either case the
        // first real bulk transfer will surface the real error.
      }

      _setState(TransportState.ready);
    } on Object {
      await _cleanup();
      _setState(TransportState.failed);
      rethrow;
    }
  }

  Future<UsbDevice?> _findNikonDevice(String? preferredIdentifier) async {
    final devices = await QuickUsb.getDeviceList();
    // Prefer an exact match by device identifier (opaque per-plug string
    // sourced from Android's UsbDevice.getDeviceName / libusb bus:addr).
    // Fall back to the first Nikon we see — the 99% case is "one camera
    // plugged in".
    UsbDevice? firstNikon;
    for (final d in devices) {
      if (!NikonUsbIds.isNikon(d.vendorId)) continue;
      firstNikon ??= d;
      if (preferredIdentifier != null &&
          preferredIdentifier.isNotEmpty &&
          d.identifier == preferredIdentifier) {
        return d;
      }
    }
    return firstNikon;
  }

  Future<(UsbInterface, UsbEndpoint, UsbEndpoint)>
      _claimStillImageInterface() async {
    final config = await QuickUsb.getConfiguration(0);
    for (final iface in config.interfaces) {
      // USB Still Image Class 1.0 mandates the PTP interface expose exactly
      // one Bulk-OUT, one Bulk-IN and one Interrupt-IN, in that enumeration
      // order. quick_usb 0.4.0 doesn't expose the endpoint TYPE (only its
      // direction), so we take the FIRST OUT and the FIRST IN — for a
      // spec-compliant Nikon body this deterministically gives us the
      // bulk pair (the interrupt-IN comes later in the list).
      UsbEndpoint? bulkIn;
      UsbEndpoint? bulkOut;
      for (final ep in iface.endpoints) {
        if (ep.direction == UsbEndpoint.DIRECTION_IN) {
          bulkIn ??= ep;
        } else if (ep.direction == UsbEndpoint.DIRECTION_OUT) {
          bulkOut ??= ep;
        }
      }
      if (bulkIn != null && bulkOut != null) {
        final claimed = await QuickUsb.claimInterface(iface);
        if (!claimed) {
          throw const PtpTransportException(
            'claim interface 失败 — 可能被系统 MTP 服务占用',
          );
        }
        return (iface, bulkIn, bulkOut);
      }
    }
    throw const PtpTransportException(
      '未找到 PTP bulk-IN/OUT 端点对 — 相机 USB 模式可能不是 MTP/PTP',
    );
  }

  @override
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    _requireReady();
    final txId = ++_transactionId;
    final timeoutMs = (timeout ?? const Duration(seconds: 30)).inMilliseconds;

    cancelToken?.throwIfCancelled();

    // 1. Command block.
    final cmd = PtpUsbCodec.encodeCommand(
      opcode: transaction.opcode,
      transactionId: txId,
      params: transaction.params,
    );
    await _bulkWrite(cmd, timeoutMs);

    // 2. Data-out phase (host → device), if any.
    if (transaction.dataPhase == PtpDataPhase.dataOut &&
        transaction.dataOut != null) {
      cancelToken?.throwIfCancelled();
      final payload = transaction.dataOut!;
      final data = PtpUsbCodec.encodeData(
        opcode: transaction.opcode,
        transactionId: txId,
        payload: payload,
      );
      await _bulkWrite(data, timeoutMs);
    }

    // 3. Data-in phase (device → host), if requested.
    Uint8List? dataIn;
    if (transaction.dataPhase == PtpDataPhase.dataIn) {
      cancelToken?.throwIfCancelled();
      final container = await _readContainer(timeoutMs);
      if (container.type == PtpUsbContainerType.data) {
        if (container.transactionId != txId) {
          throw PtpProtocolException(
            'data transactionId mismatch: sent $txId got ${container.transactionId}',
          );
        }
        dataIn = container.payload;
      } else if (container.type == PtpUsbContainerType.response) {
        // Some commands with dataPhase=dataIn legitimately skip data
        // (e.g. GetThumb on an object with no thumbnail) and go straight
        // to a non-OK response. Return that immediately.
        return _responseFromContainer(container, dataIn: null);
      } else {
        throw PtpProtocolException(
          'expected data or response, got ${container.type}',
        );
      }
    }

    // 4. Response block.
    cancelToken?.throwIfCancelled();
    final resp = await _readContainer(timeoutMs);
    if (resp.type != PtpUsbContainerType.response) {
      throw PtpProtocolException(
        'expected response, got ${resp.type}',
      );
    }
    if (resp.transactionId != txId) {
      throw PtpProtocolException(
        'response transactionId mismatch: sent $txId got ${resp.transactionId}',
      );
    }
    return _responseFromContainer(resp, dataIn: dataIn);
  }

  PtpResponse _responseFromContainer(
    PtpUsbContainer c, {
    required Uint8List? dataIn,
  }) {
    return PtpResponse(
      code: c.code,
      params: PtpUsbCodec.decodeParams(c.payload),
      data: dataIn,
    );
  }

  @override
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  }) async* {
    // No sub-chunk streaming exposed by PTP-USB — the data block arrives as
    // one logical payload. Callers wanting per-chunk yield (Live View,
    // large downloads) should use NikonZClient.downloadObject which slices
    // via GetPartialObjectEx.
    final resp = await sendTransaction(
      transaction,
      cancelToken: cancelToken,
    );
    final data = resp.data;
    if (data != null && data.isNotEmpty) yield data;
  }

  Future<void> _bulkWrite(Uint8List bytes, int timeoutMs) async {
    final ep = _bulkOut;
    if (ep == null) {
      throw const PtpTransportException('bulk-OUT endpoint not configured');
    }
    final written = await QuickUsb.bulkTransferOut(ep, bytes, timeout: timeoutMs);
    if (written != bytes.length) {
      throw PtpTransportException(
        'short bulk write: sent $written / ${bytes.length}',
      );
    }
  }

  /// Read one full PTP-USB container from the bulk-IN endpoint. Handles the
  /// common case of the container spanning multiple bulk transfers by
  /// following the length field in the 12-byte header.
  Future<PtpUsbContainer> _readContainer(int timeoutMs) async {
    final ep = _bulkIn;
    if (ep == null) {
      throw const PtpTransportException('bulk-IN endpoint not configured');
    }

    final first = await QuickUsb.bulkTransferIn(ep, _readBufferSize, timeout: timeoutMs);
    if (first.length < PtpUsbCodec.headerBytes) {
      throw PtpProtocolException(
        'runt bulk read: ${first.length} bytes < 12B header',
      );
    }
    final header = PtpUsbCodec.peekHeader(first);
    if (header.length <= first.length) {
      return PtpUsbCodec.decode(
        Uint8List.sublistView(first, 0, header.length),
      );
    }

    // Container spans multiple bulk transfers — accumulate.
    final buf = BytesBuilder()..add(first);
    while (buf.length < header.length) {
      final want = header.length - buf.length;
      // Read at most our buffer size at a time; the device will terminate
      // the last transfer with a short packet or ZLP.
      final chunk = await QuickUsb.bulkTransferIn(
        ep,
        want < _readBufferSize ? want : _readBufferSize,
        timeout: timeoutMs,
      );
      if (chunk.isEmpty) break;
      buf.add(chunk);
    }
    if (buf.length < header.length) {
      throw PtpProtocolException(
        'container short read: got ${buf.length} / ${header.length}',
      );
    }
    return PtpUsbCodec.decode(
      Uint8List.sublistView(buf.toBytes(), 0, header.length),
    );
  }

  void _requireReady() {
    if (_state != TransportState.ready) {
      throw const PtpTransportException('USB transport not ready');
    }
  }

  void _setState(TransportState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  Future<void> _cleanup() async {
    final iface = _interface;
    if (iface != null) {
      try {
        await QuickUsb.releaseInterface(iface);
      } on Object {
        // Best-effort.
      }
    }
    if (_device != null) {
      try {
        await QuickUsb.closeDevice();
      } on Object {
        // Best-effort.
      }
    }
    _interface = null;
    _bulkIn = null;
    _bulkOut = null;
    _device = null;
  }

  @override
  Future<void> close() async {
    if (_state == TransportState.closed) return;
    _setState(TransportState.closing);
    await _cleanup();
    _setState(TransportState.closed);
  }
}
