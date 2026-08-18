import 'package:meta/meta.dart';

/// The Nikon Z body currently connected — determined from
/// [DeviceInfo.model] at connect time.
enum NikonZModel {
  z5('Z 5'),
  z6('Z 6'),
  z6ii('Z 6II'),
  z6iii('Z 6III'),
  z7('Z 7'),
  z7ii('Z 7II'),
  z8('Z 8'),
  z9('Z 9'),
  zf('Z f'),
  zfc('Z fc'),
  z50('Z 50'),
  z50ii('Z 50II'),
  z30('Z 30'),
  unknown('Unknown');

  const NikonZModel(this.displayName);

  final String displayName;

  static NikonZModel fromModelString(String raw) {
    final n = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return switch (n) {
      'nikonz5' || 'z5' => z5,
      'nikonz6' || 'z6' => z6,
      'nikonz6_2' || 'z6ii' || 'nikonz6ii' => z6ii,
      'nikonz6_3' || 'z6iii' || 'nikonz6iii' => z6iii,
      'nikonz7' || 'z7' => z7,
      'nikonz7_2' || 'z7ii' || 'nikonz7ii' => z7ii,
      'nikonz8' || 'z8' => z8,
      'nikonz9' || 'z9' => z9,
      'nikonzf' || 'zf' => zf,
      'nikonzfc' || 'zfc' => zfc,
      'nikonz50' || 'z50' => z50,
      'nikonz50ii' || 'z50_2' => z50ii,
      'nikonz30' || 'z30' => z30,
      _ => unknown,
    };
  }
}

/// Behavior overrides for a given (model + firmware) pair.
///
/// Populated from `quirks.dart` at connect time. Keeps the client layer
/// free of model-specific `if` chains.
@immutable
final class NikonZQuirks {
  const NikonZQuirks({
    required this.model,
    required this.firmware,
    this.useLegacyLiveViewOpcode = false,
    this.needsChangeApplicationMode = true,
    this.liveViewFallbackFps = 20,
    this.liveViewMaxFps = 30,
  });

  final NikonZModel model;
  final String firmware;

  /// Older Z bodies (Z50 / Zfc / early Z6 firmware) only implement
  /// GetLiveViewImg (0x9203) instead of 0x9428.
  final bool useLegacyLiveViewOpcode;

  /// Every Z body needs ChangeApplicationMode(1) after OpenSession
  /// except a few older firmware branches. Default true; quirks can flip.
  final bool needsChangeApplicationMode;

  final int liveViewFallbackFps;
  final int liveViewMaxFps;

  static NikonZQuirks defaults(NikonZModel model, String firmware) {
    return NikonZQuirks(
      model: model,
      firmware: firmware,
      useLegacyLiveViewOpcode: switch (model) {
        NikonZModel.z50 || NikonZModel.zfc || NikonZModel.z30 => true,
        _ => false,
      },
    );
  }
}
