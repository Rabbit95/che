import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent client GUID for PTP-IP InitCommandRequest.
///
/// The camera whitelists paired clients by GUID; regenerating on every
/// launch would force the user to re-pair every session. Kept in
/// shared_preferences as 32 hex chars.
final class ClientGuidStore {
  ClientGuidStore({SharedPreferences? prefs}) : _prefs = prefs;

  static const String _prefsKey = 'nikon_ptp.clientGuidHex';

  SharedPreferences? _prefs;

  Future<Uint8List> readOrCreate() async {
    _prefs ??= await SharedPreferences.getInstance();
    final existing = _prefs!.getString(_prefsKey);
    if (existing != null && existing.length == 32) {
      return _hexToBytes(existing);
    }
    final bytes = _generateGuid();
    await _prefs!.setString(_prefsKey, _bytesToHex(bytes));
    return bytes;
  }

  Future<void> reset() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_prefsKey);
  }

  static Uint8List _generateGuid() {
    // RFC 4122 v4 layout — version 4, variant 10xx.
    final rnd = Random.secure();
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = rnd.nextInt(256);
    }
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    return b;
  }

  static String _bytesToHex(Uint8List b) {
    final s = StringBuffer();
    for (final byte in b) {
      s.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return s.toString();
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
