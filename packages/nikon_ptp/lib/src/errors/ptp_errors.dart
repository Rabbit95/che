import '../constants/response_codes.dart';

/// Base class for all protocol-level failures surfaced by nikon_ptp.
sealed class PtpException implements Exception {
  const PtpException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Framing / decoding failure — packet length, type, or payload malformed.
final class PtpProtocolException extends PtpException {
  const PtpProtocolException(super.message);
}

/// Transport-layer failure: socket died, USB endpoint stalled, ICC error.
final class PtpTransportException extends PtpException {
  const PtpTransportException(super.message, {this.cause});

  final Object? cause;

  @override
  String toString() =>
      cause == null ? super.toString() : '$runtimeType: $message ($cause)';
}

/// Camera returned a non-OK response code.
final class PtpResponseException extends PtpException {
  const PtpResponseException(this.code, {this.opcode, String? context})
      : super(context ?? '');

  final int code;
  final int? opcode;

  String get codeLabel => PtpResponseCode.label(code);

  bool get isBusy => code == PtpResponseCode.deviceBusy;
  bool get isNotSupported => code == PtpResponseCode.operationNotSupported;
  bool get isCancelled => code == PtpResponseCode.transactionCancelled;

  @override
  String toString() {
    final op = opcode == null
        ? ''
        : ' op=0x${opcode!.toRadixString(16).toUpperCase().padLeft(4, '0')}';
    final ctx = message.isEmpty ? '' : ' — $message';
    return 'PtpResponseException($codeLabel$op)$ctx';
  }
}

/// PTP-IP init handshake was rejected by the camera.
final class PtpIpInitFailException extends PtpException {
  const PtpIpInitFailException(this.reasonCode) : super('InitFail');

  final int reasonCode;

  String get reasonHex =>
      '0x${reasonCode.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  @override
  String toString() => 'PtpIpInitFailException(reason=$reasonHex)';
}

/// Operation cancelled via [CancelToken] or explicit cancel.
final class PtpCancelledException extends PtpException {
  const PtpCancelledException([super.message = 'cancelled']);
}

/// Operation timed out at the session level.
final class PtpTimeoutException extends PtpException {
  const PtpTimeoutException(super.message);
}
