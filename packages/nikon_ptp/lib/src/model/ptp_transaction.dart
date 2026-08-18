import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Direction of a PTP data phase, if any.
enum PtpDataPhase {
  none,
  dataIn, // device → host (we receive)
  dataOut, // host → device (we send)
}

/// A single PTP transaction request submitted to a [Transport].
@immutable
final class PtpTransaction {
  // PTP spec caps opcode params at 5 (ISO 15740 §9.3.1). We don't assert
  // here because Dart's const-evaluator disallows accessing List.length in
  // a const constructor's assert, and every constructed transaction in
  // this codebase is `const`. The codec's writer trusts the caller.
  const PtpTransaction({
    required this.opcode,
    this.params = const <int>[],
    this.dataOut,
    this.dataPhase = PtpDataPhase.none,
  });

  final int opcode;
  final List<int> params;

  /// Payload for a data-out transaction (SetDevicePropValue, etc).
  final Uint8List? dataOut;
  final PtpDataPhase dataPhase;

  @override
  String toString() {
    final hex = opcode.toRadixString(16).toUpperCase().padLeft(4, '0');
    return 'PtpTransaction(0x$hex, params=$params, phase=$dataPhase, '
        'dataOut=${dataOut?.length ?? 0}B)';
  }
}

/// The reply from a completed [PtpTransaction].
///
/// For a data-in transaction, [data] is the full concatenated payload from
/// StartData/Data*/EndData packets. For a data-out or no-data transaction it
/// is null. [params] holds the 0–5 response parameters.
@immutable
final class PtpResponse {
  const PtpResponse({
    required this.code,
    required this.params,
    this.data,
  });

  final int code;
  final List<int> params;
  final Uint8List? data;

  int? paramAt(int index) => index < params.length ? params[index] : null;

  @override
  String toString() {
    final hex = code.toRadixString(16).toUpperCase().padLeft(4, '0');
    return 'PtpResponse(0x$hex, params=$params, data=${data?.length ?? 0}B)';
  }
}
