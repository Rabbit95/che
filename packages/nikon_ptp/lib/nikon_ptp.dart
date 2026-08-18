/// Pure-Dart PTP / PTP-IP protocol implementation with Nikon Z vendor extensions.
///
/// Layered so callers can use whichever slice fits:
/// - [constants] — packet types, opcodes, event codes, response codes
/// - [model] — packet + transaction + device-info + property-desc sealed classes
/// - [codec] — LE encode/decode, packet header codec, data-phase codec
/// - [transport] — abstract [Transport] interface (Wi-Fi / USB / ICC implement it)
/// - [session] — [PtpSession] transaction state machine + operation queue
/// - [client] — [NikonZClient] high-level Z-series API
library;

export 'src/client/nikon_z_client.dart';
export 'src/client/prop_formatter.dart' show PropFormatter, kCorePropCodes;
export 'src/codec/byte_reader.dart' show ByteReader, encodeUtf16LeNullTerminated;
export 'src/codec/byte_writer.dart' show ByteWriter;
export 'src/codec/live_view_frame_codec.dart' show LiveViewFrameCodec;
export 'src/codec/packet_framer.dart' show PacketFramer;
export 'src/codec/ptp_data_codec.dart' show PtpDataCodec;
export 'src/codec/ptpip_codec.dart' show PtpIpCodec;
export 'src/codec/ptpusb_codec.dart'
    show PtpUsbCodec, PtpUsbContainer, PtpUsbContainerType, PtpUsbHeader;
export 'src/constants/event_codes.dart';
export 'src/constants/nikon_opcodes.dart';
export 'src/constants/packet_types.dart';
export 'src/constants/prop_codes.dart';
export 'src/constants/response_codes.dart';
export 'src/constants/standard_opcodes.dart';
export 'src/errors/ptp_errors.dart';
export 'src/model/camera_event.dart';
export 'src/model/device_info.dart';
export 'src/model/device_prop_desc.dart';
export 'src/model/live_view_frame.dart';
export 'src/model/nikon_z_model.dart';
export 'src/model/object_info.dart';
export 'src/model/ptp_ip_packet.dart';
export 'src/model/ptp_transaction.dart';
export 'src/model/storage_info.dart';
export 'src/session/operation_queue.dart' show OpPriority;
export 'src/session/ptp_session.dart';
export 'src/transport/cancel_token.dart';
export 'src/transport/transport.dart';
