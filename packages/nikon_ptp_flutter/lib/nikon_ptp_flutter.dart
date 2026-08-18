/// Flutter-side transport implementations for the nikon_ptp protocol.
///
/// - [PtpIpTransport] — Wi-Fi (dart:io Socket), all platforms
/// - [UsbTransport] — Android (quick_usb bulk endpoints), stub included
/// - [IccTransport] — iOS iPhone + iPad (ICCameraDevice), stub included
library;

export 'src/client_guid_store.dart';
export 'src/icc_channel.dart';
export 'src/icc_discovery.dart';
export 'src/icc_transport.dart';
export 'src/nikon_usb_ids.dart';
export 'src/ptpip_transport.dart';
export 'src/usb_discovery.dart';
export 'src/usb_transport.dart';
