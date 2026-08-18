import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nikon_ptp/nikon_ptp.dart';

import 'connection_providers.dart';

/// User-facing error emitted when a control command fails.
///
/// Wraps the raw PTP response with a Chinese hint keyed off the response
/// code. Kept as a plain [Exception] (not a sealed class) so the UI can
/// `catch` it uniformly and read [userMessage].
@immutable
final class CameraControlFailure implements Exception {
  const CameraControlFailure({
    required this.action,
    required this.summary,
    this.hint,
    this.code,
    this.opcode,
    this.cause,
  });

  /// Short verb naming the action that failed — e.g. "拍照失败", "写入 ISO 失败".
  final String action;

  /// Machine-oriented label ("AccessDenied", "0xA00E", "Socket closed").
  final String summary;

  /// Optional Chinese hint mapped from [code]. May be null when the code
  /// isn't in [_hintForResponse].
  final String? hint;

  final int? code;
  final int? opcode;
  final Object? cause;

  /// One-line message safe to drop into a SnackBar.
  String get userMessage {
    final base = '$action: $summary';
    return hint == null ? base : '$base — $hint';
  }

  @override
  String toString() => 'CameraControlFailure($userMessage)';

  /// Build from a [PtpResponseException] surfaced by [NikonZClient].
  factory CameraControlFailure.fromPtp(
    PtpResponseException e, {
    required String action,
  }) {
    return CameraControlFailure(
      action: action,
      summary: e.codeLabel,
      hint: _hintForResponse(e.code),
      code: e.code,
      opcode: e.opcode,
      cause: e,
    );
  }

  /// Build from any other error type (transport failures, cancellations,
  /// timeouts, unexpected `Object`s from a fake in tests, etc.).
  factory CameraControlFailure.fromError(
    Object error, {
    required String action,
  }) {
    if (error is PtpResponseException) {
      return CameraControlFailure.fromPtp(error, action: action);
    }
    return CameraControlFailure(
      action: action,
      summary: error.toString(),
      cause: error,
    );
  }
}

/// Minimal command surface used by [CameraCommands]. Widened for tests so
/// they can supply a plain fake instead of standing up a real session +
/// transport pair.
abstract interface class CameraCommandTarget {
  Future<void> capture();
  Future<void> setProperty(int propCode, int dataType, Object value);
  Future<void> startMovieRecording();
  Future<void> stopMovieRecording();
}

/// Adapter around [NikonZClient]. Trivial by design — the client already
/// has these method shapes; this exists purely to open a seam for tests.
final class _ClientCommandTarget implements CameraCommandTarget {
  const _ClientCommandTarget(this._client);
  final NikonZClient _client;

  @override
  Future<void> capture() => _client.capture();

  @override
  Future<void> setProperty(int propCode, int dataType, Object value) =>
      _client.setProperty(propCode, dataType, value);

  @override
  Future<void> startMovieRecording() => _client.startMovieRecording();

  @override
  Future<void> stopMovieRecording() => _client.stopMovieRecording();
}

/// High-level camera command dispatcher.
///
/// Every method translates raw [PtpResponseException]s (and any other
/// transport error) into a [CameraControlFailure] so widgets can just
/// `catch (CameraControlFailure e)` and render [e.userMessage].
///
/// Kept as a plain class (no Flutter/Riverpod deps) so it's trivial to
/// unit-test with an in-memory [CameraCommandTarget].
final class CameraCommands {
  const CameraCommands(this._target);

  final CameraCommandTarget _target;

  /// Fire the shutter. Throws [CameraControlFailure] on any error.
  Future<void> capture() async {
    try {
      await _target.capture();
    } catch (e) {
      throw CameraControlFailure.fromError(e, action: '拍照失败');
    }
  }

  /// Begin video recording. Throws [CameraControlFailure] on failure.
  Future<void> startMovieRecording() async {
    try {
      await _target.startMovieRecording();
    } catch (e) {
      throw CameraControlFailure.fromError(e, action: '开始录像失败');
    }
  }

  /// End video recording. Throws [CameraControlFailure] on failure.
  Future<void> stopMovieRecording() async {
    try {
      await _target.stopMovieRecording();
    } catch (e) {
      throw CameraControlFailure.fromError(e, action: '停止录像失败');
    }
  }

  /// Write a single property. [dataType] must match the on-wire type from
  /// the corresponding [DevicePropDesc]. Throws [CameraControlFailure]
  /// on failure; the caller is responsible for waiting on the property
  /// snapshot to reflect the new value (event-driven, handled elsewhere).
  Future<void> setProperty(
    int propCode,
    int dataType,
    Object value, {
    String? actionLabel,
  }) async {
    final action = actionLabel ?? '写入参数失败';
    try {
      await _target.setProperty(propCode, dataType, value);
    } catch (e) {
      throw CameraControlFailure.fromError(e, action: action);
    }
  }
}

/// Provides a [CameraCommands] bound to the currently active connection,
/// or `null` when no camera is connected.
///
/// Widgets typically do `ref.watch(cameraCommandsProvider)` and disable
/// their action buttons when the value is null.
final Provider<CameraCommands?> cameraCommandsProvider =
    Provider<CameraCommands?>((ref) {
  final active = ref.watch(activeConnectionProvider);
  if (active == null) return null;
  return CameraCommands(_ClientCommandTarget(active.client));
});

/// Actionable Chinese hint keyed by PTP response code. Kept centralised
/// here so ParameterSheet / LiveView / TransferQueue can all report the
/// same phrasing when the same code comes back from a different opcode.
///
/// Returns null when there's nothing useful to add beyond the code label
/// (the UI will just show the label).
String? _hintForResponse(int code) {
  return switch (code) {
    PtpResponseCode.accessDenied =>
      '相机不允许该操作，通常是 USB 模式不对（应设 MTP/PTP，非 iPhone 模式）或未在相机上完成配对',
    PtpResponseCode.sessionAlreadyOpen =>
      '上次会话未关闭，重启相机 Wi-Fi 或拔插 USB 一次',
    PtpResponseCode.sessionNotOpen =>
      '会话已断开，请返回发现界面重新连接',
    PtpResponseCode.deviceBusy =>
      '相机正忙（可能在录像/连拍/菜单中），退到主界面后重试',
    PtpResponseCode.operationNotSupported =>
      '当前固件不支持该命令，可能需要升级相机固件',
    PtpResponseCode.storeNotAvailable =>
      '未检测到存储卡，请检查卡槽',
    PtpResponseCode.storeFull =>
      '存储卡已满',
    PtpResponseCode.invalidDevicePropValue =>
      '该档位相机拒绝，检查相机是否在允许写入该属性的模式（如手动 M 才能改快门/光圈）',
    PtpResponseCode.devicePropNotSupported =>
      '当前机型不支持该属性',
    PtpResponseCode.captureAlreadyTerminated =>
      '拍摄已结束（可能已自动停止）',
    PtpResponseCode.nikonHardwareError =>
      '相机硬件报错，重启相机后重试',
    PtpResponseCode.nikonOutOfFocus =>
      '对焦失败，切换到 MF 或换个对焦点再试',
    PtpResponseCode.nikonChangeCameraModeFailed =>
      '相机模式切换失败，检查是否处于允许控制的模式',
    PtpResponseCode.nikonInvalidStatus =>
      '相机当前状态不允许该操作（如正在回放/菜单中）',
    PtpResponseCode.nikonBulbReleaseBusy =>
      'B 门释放中，请稍候',
    _ => null,
  };
}

/// Testing seam — exposed for the unit tests only.
@visibleForTesting
String? debugHintForResponse(int code) => _hintForResponse(code);
