import 'dart:typed_data';

/// Little-endian byte-stream writer. Grows automatically.
final class ByteWriter {
  // copy: true is required because we hand BytesBuilder views onto the
  // reused _scratch ByteData below; without a copy on add() every prior
  // multi-byte write would be overwritten by the next.
  ByteWriter()
      : _bytes = BytesBuilder(),
        _scratch = ByteData(8);

  final BytesBuilder _bytes;
  final ByteData _scratch;

  int get length => _bytes.length;

  void writeU8(int value) {
    _bytes.addByte(value & 0xFF);
  }

  void writeI8(int value) {
    _scratch.setInt8(0, value);
    _bytes.add(_scratch.buffer.asUint8List(0, 1));
  }

  void writeU16(int value) {
    _scratch.setUint16(0, value, Endian.little);
    _bytes.add(_scratch.buffer.asUint8List(0, 2));
  }

  void writeI16(int value) {
    _scratch.setInt16(0, value, Endian.little);
    _bytes.add(_scratch.buffer.asUint8List(0, 2));
  }

  void writeU32(int value) {
    _scratch.setUint32(0, value, Endian.little);
    _bytes.add(_scratch.buffer.asUint8List(0, 4));
  }

  void writeI32(int value) {
    _scratch.setInt32(0, value, Endian.little);
    _bytes.add(_scratch.buffer.asUint8List(0, 4));
  }

  void writeU64(int value) {
    _scratch.setUint64(0, value, Endian.little);
    _bytes.add(_scratch.buffer.asUint8List(0, 8));
  }

  void writeI64(int value) {
    _scratch.setInt64(0, value, Endian.little);
    _bytes.add(_scratch.buffer.asUint8List(0, 8));
  }

  void writeBytes(List<int> data) {
    _bytes.add(data);
  }

  /// PTP "String" — uint8 length (in code units, includes null),
  /// then UTF-16LE code units, then a UTF-16LE null. Empty string
  /// is a single 0x00 byte (no code units, no terminator).
  void writePtpString(String s) {
    if (s.isEmpty) {
      writeU8(0);
      return;
    }
    final units = s.codeUnits;
    writeU8(units.length + 1); // + terminator
    for (final cu in units) {
      writeU16(cu);
    }
    writeU16(0);
  }

  /// UTF-16LE null-terminated string (no length prefix).
  void writeUtf16LeNullTerminated(String s) {
    for (final cu in s.codeUnits) {
      writeU16(cu);
    }
    writeU16(0);
  }

  void writeUint16Array(List<int> values) {
    writeU32(values.length);
    for (final v in values) {
      writeU16(v);
    }
  }

  void writeUint32Array(List<int> values) {
    writeU32(values.length);
    for (final v in values) {
      writeU32(v);
    }
  }

  Uint8List takeBytes() => _bytes.takeBytes();
  Uint8List toBytes() => _bytes.toBytes();
}
