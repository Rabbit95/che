import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../model/camera_event.dart';
import '../model/ptp_transaction.dart';
import 'cancel_token.dart';

/// Which physical link a [Transport] uses. Presentation surfaces this
/// (green USB / blue Wi-Fi badges in the UI).
enum TransportChannel { wifi, usb, icc }

/// Immutable per-connection configuration.
@immutable
final class TransportConfig {
  const TransportConfig({
    required this.channel,
    this.host,
    this.port,
    this.usbSerial,
    this.iccDeviceId,
    this.friendlyName = 'Nikon Z Control',
  });

  factory TransportConfig.wifi({
    required String host,
    int port = 15740,
    String friendlyName = 'Nikon Z Control',
  }) =>
      TransportConfig(
        channel: TransportChannel.wifi,
        host: host,
        port: port,
        friendlyName: friendlyName,
      );

  factory TransportConfig.usb({
    required String usbSerial,
    String friendlyName = 'Nikon Z Control',
  }) =>
      TransportConfig(
        channel: TransportChannel.usb,
        usbSerial: usbSerial,
        friendlyName: friendlyName,
      );

  factory TransportConfig.icc({
    required String iccDeviceId,
    String friendlyName = 'Nikon Z Control',
  }) =>
      TransportConfig(
        channel: TransportChannel.icc,
        iccDeviceId: iccDeviceId,
        friendlyName: friendlyName,
      );

  final TransportChannel channel;
  final String? host;
  final int? port;
  final String? usbSerial;
  final String? iccDeviceId;
  final String friendlyName;
}

/// Snapshot of a transport's lifecycle state.
enum TransportState {
  idle,
  connecting,
  ready,
  closing,
  closed,
  failed,
}

/// Abstract transport layer — one implementation per physical channel.
///
/// The [PtpSession] on top consumes ONLY this interface, so protocol
/// logic stays identical across Wi-Fi, USB, and iOS ImageCapture.
abstract class Transport {
  TransportChannel get channel;
  TransportState get state;
  Stream<TransportState> get stateChanges;
  Stream<CameraEvent> get events;

  Future<void> open(TransportConfig config);

  /// Submit one transaction; returns the completed [PtpResponse].
  ///
  /// The concrete implementation is responsible for the data phase:
  /// if [PtpTransaction.dataPhase] is [PtpDataPhase.dataIn] the reply's
  /// `data` field is populated; if it's [PtpDataPhase.dataOut] the
  /// [PtpTransaction.dataOut] bytes are written before the response arrives.
  Future<PtpResponse> sendTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
    Duration? timeout,
  });

  /// Stream a large data-in payload chunk by chunk. Used for Live View
  /// (per-frame) and downloads (per-chunk with [PtpDataPhase.dataIn]).
  Stream<Uint8List> streamTransaction(
    PtpTransaction transaction, {
    CancelToken? cancelToken,
  });

  Future<void> close();
}
