import 'package:meta/meta.dart';

/// A camera-originated asynchronous event.
///
/// Comes from either a PTP-IP [EventPacket] on the event socket, from the
/// USB interrupt endpoint, or from ICC's device-delegate callbacks.
@immutable
final class CameraEvent {
  const CameraEvent({
    required this.code,
    this.transactionId = 0,
    this.p1 = 0,
    this.p2 = 0,
    this.p3 = 0,
  });

  final int code;
  final int transactionId;
  final int p1;
  final int p2;
  final int p3;

  @override
  String toString() {
    final hex = code.toRadixString(16).toUpperCase().padLeft(4, '0');
    return 'CameraEvent(0x$hex, tx=$transactionId, p=[$p1,$p2,$p3])';
  }
}
