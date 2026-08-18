import 'dart:async';
import 'dart:io';

import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:nikon_ptp_flutter/nikon_ptp_flutter.dart';

/// UI log rendering hint.
enum ConnectionLogLevel { info, active, ok, error }

/// Emitted by [ConnectionController.connect*] as the handshake progresses.
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// A single log line to append to the on-screen console.
final class ConnectionLog extends ConnectionEvent {
  const ConnectionLog({
    required this.tag,
    required this.text,
    required this.level,
    this.elapsedMs,
  });

  final String tag;
  final String text;
  final ConnectionLogLevel level;

  /// Wall-clock elapsed since the handshake started. Null while a step is
  /// in progress (renderer shows a spinner instead of a duration).
  final int? elapsedMs;
}

/// Handshake completed. Caller owns [transport] / [session] / [client] and
/// is responsible for their eventual disposal.
final class ConnectionReady extends ConnectionEvent {
  const ConnectionReady({
    required this.transport,
    required this.session,
    required this.client,
    required this.deviceInfo,
  });

  final Transport transport;
  final PtpSession session;
  final NikonZClient client;
  final DeviceInfo deviceInfo;
}

/// Terminal failure. The controller has already torn down any partial state.
final class ConnectionFailed extends ConnectionEvent {
  const ConnectionFailed({required this.message, required this.cause});

  final String message;
  final Object cause;
}

/// Drives a single handshake to a Nikon Z body over either Wi-Fi or USB
/// and reports progress as a stream of [ConnectionEvent]s.
///
/// Not a Riverpod provider — deliberately a plain object so the screen owns
/// its lifecycle, and so it's easy to unit-test with an injected transport.
class ConnectionController {
  ConnectionController({
    Transport Function(TransportChannel channel)? transportFactory,
  }) : _transportFactory = transportFactory ?? _defaultTransportFactory;

  final Transport Function(TransportChannel) _transportFactory;

  static Transport _defaultTransportFactory(TransportChannel channel) {
    return switch (channel) {
      TransportChannel.wifi => PtpIpTransport(),
      TransportChannel.usb => UsbTransport(),
      TransportChannel.icc => throw UnimplementedError(
          'iOS ImageCapture transport not yet implemented (M6)',
        ),
    };
  }

  Transport? _transport;
  PtpSession? _session;
  bool _cancelled = false;
  bool _handedOff = false;

  /// Wi-Fi handshake to `host:port`.
  Stream<ConnectionEvent> connectWifi({
    required String host,
    int port = 15740,
    String friendlyName = 'Nikon Z Control',
  }) =>
      _runHandshake(
        transportChannel: TransportChannel.wifi,
        config: TransportConfig.wifi(
          host: host,
          port: port,
          friendlyName: friendlyName,
        ),
        initialLog: ConnectionLog(
          tag: 'TCP',
          text: '连接 $host:$port',
          level: ConnectionLogLevel.active,
        ),
        handshakeCompleteMessage: 'InitCommand + InitEvent 握手完成',
        handshakeTag: 'PTPIP',
      );

  /// USB handshake — optionally scoped to a specific device serial.
  Stream<ConnectionEvent> connectUsb({
    String? usbSerial,
    String friendlyName = 'Nikon Z Control',
  }) =>
      _runHandshake(
        transportChannel: TransportChannel.usb,
        config: TransportConfig.usb(
          usbSerial: usbSerial ?? '',
          friendlyName: friendlyName,
        ),
        initialLog: const ConnectionLog(
          tag: 'USB',
          text: 'claim interface + bulk 端点',
          level: ConnectionLogLevel.active,
        ),
        handshakeCompleteMessage: 'PTP-USB 接口已就绪',
        handshakeTag: 'USB',
      );

  Stream<ConnectionEvent> _runHandshake({
    required TransportChannel transportChannel,
    required TransportConfig config,
    required ConnectionLog initialLog,
    required String handshakeTag,
    required String handshakeCompleteMessage,
  }) async* {
    final sw = Stopwatch()..start();

    ConnectionLog log(
      String tag,
      String text, {
      required ConnectionLogLevel level,
      bool timed = true,
    }) =>
        ConnectionLog(
          tag: tag,
          text: text,
          level: level,
          elapsedMs: timed ? sw.elapsedMilliseconds : null,
        );

    yield initialLog;

    final transport = _transportFactory(transportChannel);
    _transport = transport;

    try {
      await transport.open(config);
      if (_cancelled) return;
      yield log(
        handshakeTag,
        handshakeCompleteMessage,
        level: ConnectionLogLevel.ok,
      );

      final session = PtpSession(transport: transport);
      _session = session;
      final client = NikonZClient(session);

      yield log(
        'CTRL',
        'OpenSession + GetDeviceInfo…',
        level: ConnectionLogLevel.active,
        timed: false,
      );

      final info = await client.connect();
      if (_cancelled) {
        await client.disconnect(sendCloseSession: false);
        return;
      }

      yield log(
        'CTRL',
        'ChangeApplicationMode(1) 完成',
        level: ConnectionLogLevel.ok,
      );
      yield log(
        'READY',
        '${info.model} · SN ${info.serialNumber} · ${info.deviceVersion}',
        level: ConnectionLogLevel.ok,
      );

      _handedOff = true;
      yield ConnectionReady(
        transport: transport,
        session: session,
        client: client,
        deviceInfo: info,
      );
    } on PtpIpInitFailException catch (e) {
      yield log(
        'PTPIP',
        'InitFail — 相机拒绝握手（reason 0x'
            '${e.reasonCode.toRadixString(16).padLeft(4, '0').toUpperCase()}），'
            '通常表示未在相机上完成配对',
        level: ConnectionLogLevel.error,
      );
      await _teardown();
      yield ConnectionFailed(message: '相机拒绝握手', cause: e);
    } on PtpTimeoutException catch (e) {
      yield log(
        transportChannel == TransportChannel.usb ? 'USB' : 'TCP',
        '连接超时 — 检查手机是否已连接到相机 Wi-Fi',
        level: ConnectionLogLevel.error,
      );
      await _teardown();
      yield ConnectionFailed(message: '连接超时', cause: e);
    } on PtpResponseException catch (e) {
      final opName = e.opcode == null
          ? '(unknown)'
          : _opcodeName(e.opcode!);
      final hint = _hintForResponse(e.code);
      yield log(
        'CTRL',
        '$opName 失败: ${e.codeLabel}${hint == null ? '' : ' — $hint'}',
        level: ConnectionLogLevel.error,
      );
      await _teardown();
      yield ConnectionFailed(
        message: '$opName 失败: ${e.codeLabel}${hint == null ? '' : ' — $hint'}',
        cause: e,
      );
    } on PtpTransportException catch (e) {
      yield log(
        transportChannel == TransportChannel.usb ? 'USB' : 'TCP',
        e.message,
        level: ConnectionLogLevel.error,
      );
      await _teardown();
      yield ConnectionFailed(message: '传输层错误: ${e.message}', cause: e);
    } on SocketException catch (e) {
      yield log(
        'TCP',
        _friendlySocketError(e),
        level: ConnectionLogLevel.error,
      );
      await _teardown();
      yield ConnectionFailed(message: _friendlySocketError(e), cause: e);
    } on TimeoutException catch (e) {
      yield log(
        'TCP',
        '连接超时（8s） — 相机 IP 或网络可能不可达',
        level: ConnectionLogLevel.error,
      );
      await _teardown();
      yield ConnectionFailed(message: '连接超时', cause: e);
    }
  }

  /// Cancels an in-flight handshake and tears the transport down.
  /// Safe to call multiple times.
  Future<void> cancel() async {
    _cancelled = true;
    await _teardown();
  }

  /// Tear down the partial connection state — called on both failure and
  /// explicit cancel. Skipped once [connect*] has handed the session off
  /// via [ConnectionReady] (the caller then owns the lifecycle).
  Future<void> _teardown() async {
    if (_handedOff) return;
    final session = _session;
    _session = null;
    if (session != null) {
      try {
        await session.close(sendCloseSession: false);
      } on Object {
        // Best-effort teardown; caller is already in a failure path.
      }
    }
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.close();
      } on Object {
        // Same — the failure path shouldn't itself throw.
      }
    }
  }

  static String _friendlySocketError(SocketException e) {
    final os = e.osError;
    if (os == null) return e.message;
    // Windows WSAECONNREFUSED = 10061; POSIX ECONNREFUSED = 111.
    if (os.errorCode == 10061 || os.errorCode == 111) {
      return '拒绝连接 — 请确认相机 Wi-Fi 已开启';
    }
    // WSAEHOSTUNREACH = 10065; EHOSTUNREACH = 113.
    if (os.errorCode == 10065 || os.errorCode == 113) {
      return '主机不可达 — 手机可能未连接到相机的 Wi-Fi';
    }
    return '${e.message} (${os.errorCode})';
  }

  /// Short human-readable name for a PTP opcode — used only for error
  /// messages, so it's fine to only cover the ones the connect flow uses.
  static String _opcodeName(int opcode) {
    return switch (opcode) {
      StandardOpcode.getDeviceInfo => 'GetDeviceInfo (0x1001)',
      StandardOpcode.openSession => 'OpenSession (0x1002)',
      StandardOpcode.closeSession => 'CloseSession (0x1003)',
      StandardOpcode.getStorageIds => 'GetStorageIDs (0x1004)',
      StandardOpcode.getStorageInfo => 'GetStorageInfo (0x1005)',
      StandardOpcode.getDevicePropDesc => 'GetDevicePropDesc (0x1014)',
      StandardOpcode.getDevicePropValue => 'GetDevicePropValue (0x1015)',
      StandardOpcode.setDevicePropValue => 'SetDevicePropValue (0x1016)',
      NikonOpcode.changeApplicationMode => 'ChangeApplicationMode (0x9435)',
      NikonOpcode.deviceReady => 'DeviceReady (0x90C8)',
      NikonOpcode.startLiveView => 'StartLiveView (0x9201)',
      NikonOpcode.endLiveView => 'EndLiveView (0x9202)',
      NikonOpcode.initiateCaptureRecInMedia => 'Capture (0x9207)',
      _ =>
        'opcode 0x${opcode.toRadixString(16).toUpperCase().padLeft(4, '0')}',
    };
  }

  /// Actionable hint for the user, keyed by response code. Returns null
  /// when there's nothing useful to say beyond the code label.
  static String? _hintForResponse(int code) {
    return switch (code) {
      PtpResponseCode.accessDenied =>
        '相机不允许进入控制模式，通常是 USB 模式不对（应设 MTP/PTP，不是"iPhone 模式"）或未在相机上完成配对',
      PtpResponseCode.sessionAlreadyOpen =>
        '上次会话未关闭，重启相机 Wi-Fi 或拔插 USB 一次',
      PtpResponseCode.deviceBusy =>
        '相机正忙（可能在录像/连拍/菜单中），退到主界面后重试',
      PtpResponseCode.operationNotSupported =>
        '当前固件不支持该命令，可能需要升级相机固件',
      PtpResponseCode.storeNotAvailable =>
        '未检测到存储卡',
      _ => null,
    };
  }
}
