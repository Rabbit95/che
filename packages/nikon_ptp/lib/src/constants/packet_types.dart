/// PTP-IP packet types from ISO 15740 §7 and the PIMA 15740 PTP-IP addendum.
///
/// Each packet on the wire begins with:
///   uint32 length  (LE, inclusive of the 8-byte header)
///   uint32 type    (LE, one of the values below)
extension type const PtpIpPacketType(int value) {
  static const PtpIpPacketType initCommandRequest = PtpIpPacketType(0x01);
  static const PtpIpPacketType initCommandAck = PtpIpPacketType(0x02);
  static const PtpIpPacketType initEventRequest = PtpIpPacketType(0x03);
  static const PtpIpPacketType initEventAck = PtpIpPacketType(0x04);
  static const PtpIpPacketType initFail = PtpIpPacketType(0x05);
  static const PtpIpPacketType cmdRequest = PtpIpPacketType(0x06);
  static const PtpIpPacketType cmdResponse = PtpIpPacketType(0x07);
  static const PtpIpPacketType event = PtpIpPacketType(0x08);
  static const PtpIpPacketType startData = PtpIpPacketType(0x09);
  static const PtpIpPacketType data = PtpIpPacketType(0x0A);
  static const PtpIpPacketType cancelTransaction = PtpIpPacketType(0x0B);
  static const PtpIpPacketType endData = PtpIpPacketType(0x0C);
  static const PtpIpPacketType ping = PtpIpPacketType(0x0D);
  static const PtpIpPacketType pong = PtpIpPacketType(0x0E);

  static const int headerBytes = 8;

  /// PTP-IP wire protocol version encoded in InitCommandRequest.
  /// Encoded as two little-endian uint16 in the order (minor, major) —
  /// note the reversed order is an easy foot-gun.
  static const int protocolVersionMinor = 0x0000;
  static const int protocolVersionMajor = 0x0001;

  /// Default TCP port for PTP-IP.
  static const int defaultPort = 15740;

  bool get isKnown => value >= 0x01 && value <= 0x0E;
}
