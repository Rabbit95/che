import 'dart:convert';
import 'dart:typed_data';

import '../errors/ptp_errors.dart';

/// Little-endian cursor over a byte buffer. All PTP / PTP-IP integers
/// are LE, and strings use UTF-16LE with a leading length byte.
///
/// Throws [PtpProtocolException] on OOB reads so decode failures are
/// distinguishable from transport failures.
final class ByteReader {
  ByteReader(Uint8List data)
      : _view = ByteData.sublistView(data),
        _bytes = data;

  final ByteData _view;
  final Uint8List _bytes;
  int _offset = 0;

  int get offset => _offset;
  int get length => _bytes.length;
  int get remaining => _bytes.length - _offset;

  bool get isDone => _offset >= _bytes.length;

  void _require(int bytes) {
    if (_offset + bytes > _bytes.length) {
      throw PtpProtocolException(
        'buffer underrun: need $bytes bytes at offset $_offset, '
        'have ${_bytes.length - _offset}',
      );
    }
  }

  int readU8() {
    _require(1);
    return _view.getUint8(_offset++);
  }

  int readI8() {
    _require(1);
    return _view.getInt8(_offset++);
  }

  int readU16() {
    _require(2);
    final v = _view.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int readI16() {
    _require(2);
    final v = _view.getInt16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int readU32() {
    _require(4);
    final v = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int readI32() {
    _require(4);
    final v = _view.getInt32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int readU64() {
    _require(8);
    final v = _view.getUint64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  int readI64() {
    _require(8);
    final v = _view.getInt64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  Uint8List readBytes(int count) {
    _require(count);
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + count);
    _offset += count;
    return slice;
  }

  Uint8List readRemaining() {
    final slice = Uint8List.sublistView(_bytes, _offset);
    _offset = _bytes.length;
    return slice;
  }

  /// PTP "String" — uint8 length (in *code units*, includes the null),
  /// followed by UTF-16LE code units, then a single UTF-16LE null.
  /// A length byte of 0 means empty string with no code units at all.
  String readPtpString() {
    final numCodeUnits = readU8();
    if (numCodeUnits == 0) return '';
    _require(numCodeUnits * 2);
    // Drop the trailing null terminator from the char count.
    final codeUnits = <int>[];
    for (var i = 0; i < numCodeUnits - 1; i++) {
      codeUnits.add(_view.getUint16(_offset, Endian.little));
      _offset += 2;
    }
    // Consume the terminator.
    _offset += 2;
    return String.fromCharCodes(codeUnits);
  }

  /// UTF-16LE, no length prefix, null-terminated. Used inside PTP-IP
  /// InitCommand handshakes (friendly name / server name).
  String readUtf16LeNullTerminated() {
    final codeUnits = <int>[];
    while (remaining >= 2) {
      final cu = _view.getUint16(_offset, Endian.little);
      _offset += 2;
      if (cu == 0) return String.fromCharCodes(codeUnits);
      codeUnits.add(cu);
    }
    // Ran out of buffer without a terminator — return what we have.
    return String.fromCharCodes(codeUnits);
  }

  /// PTP "Array" — uint32 element count followed by inline elements read
  /// via [readElement].
  List<T> readArray<T>(T Function(ByteReader r) readElement) {
    final count = readU32();
    final out = List<T>.generate(count, (_) => readElement(this));
    return out;
  }

  List<int> readUint16Array() => readArray((r) => r.readU16());
  List<int> readUint32Array() => readArray((r) => r.readU32());

  /// Used by CmdResponse to consume 0..5 uint32 params that trail the
  /// fixed header; count is derived from [remaining].
  List<int> readTrailingUint32Params({int max = 5}) {
    final count = (remaining ~/ 4).clamp(0, max);
    return List<int>.generate(count, (_) => readU32());
  }

  /// Debug helper — hex dump of the *entire* buffer with a caret at
  /// the current offset.
  String debugDump() {
    final b = StringBuffer();
    for (var i = 0; i < _bytes.length; i++) {
      if (i == _offset) b.write('|');
      b.write(_bytes[i].toRadixString(16).padLeft(2, '0'));
      if (i < _bytes.length - 1) b.write(' ');
    }
    if (_offset == _bytes.length) b.write('|');
    return b.toString();
  }
}

/// UTF-16LE encoder shared by writers.
Uint8List encodeUtf16LeNullTerminated(String s) {
  final units = s.codeUnits;
  final buf = Uint8List((units.length + 1) * 2);
  final v = ByteData.sublistView(buf);
  for (var i = 0; i < units.length; i++) {
    v.setUint16(i * 2, units[i], Endian.little);
  }
  // Terminator already 0 from Uint8List init.
  return buf;
}

/// UTF-8 escape helper for debug logging.
String debugUtf8(Uint8List b, {int max = 32}) {
  final s = b.length <= max ? b : Uint8List.sublistView(b, 0, max);
  return utf8.decode(s, allowMalformed: true);
}
