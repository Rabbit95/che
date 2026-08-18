import 'package:nikon_ptp/nikon_ptp.dart';
import 'package:test/test.dart';

void main() {
  group('PropFormatter.labelFor / longNameFor', () {
    test('returns known labels for standard props', () {
      expect(PropFormatter.labelFor(StandardPropCode.exposureIndex), 'ISO');
      expect(PropFormatter.labelFor(StandardPropCode.exposureTime), 'SHUTTER');
      expect(PropFormatter.labelFor(StandardPropCode.fNumber), 'APERTURE');
      expect(
        PropFormatter.labelFor(StandardPropCode.exposureBiasCompensation),
        'EV',
      );
      expect(PropFormatter.labelFor(StandardPropCode.whiteBalance), 'WB');
    });

    test('longNameFor returns Chinese labels for the parameter sheet', () {
      expect(PropFormatter.longNameFor(StandardPropCode.exposureTime), '快门');
      expect(PropFormatter.longNameFor(StandardPropCode.fNumber), '光圈');
      expect(PropFormatter.longNameFor(StandardPropCode.focusMode), '对焦模式');
    });

    test('unknown prop falls back to hex code', () {
      expect(PropFormatter.labelFor(0xABCD), '0xABCD');
      expect(PropFormatter.longNameFor(0xABCD), 'Prop 0xABCD');
    });
  });

  group('PropFormatter.formatValue — ISO', () {
    test('integer ISO renders as-is', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureIndex, 3200),
        '3200',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureIndex, 100),
        '100',
      );
    });

    test('sentinel value renders as AUTO', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureIndex, 0xFFFF),
        'AUTO',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureIndex, 0xFFFFFFFF),
        'AUTO',
      );
    });

    test('null renders as em dash placeholder', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureIndex, null),
        '—',
      );
    });
  });

  group('PropFormatter.formatValue — shutter speed', () {
    test('fast shutter renders as 1/N', () {
      // 1/250 s = 40 units of 0.0001 s
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 40),
        '1/250',
      );
      // 1/1000 s = 10 units
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 10),
        '1/1000',
      );
      // 1/60 s ≈ 166.67 units — rounded to 167 → 1/60 (10000/167 = 59.88 → round 60)
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 167),
        '1/60',
      );
    });

    test('long exposure renders in seconds', () {
      // 1 s
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 10000),
        '1"',
      );
      // 2.5 s
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 25000),
        '2.5"',
      );
      // 30 s
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 300000),
        '30"',
      );
    });

    test('special values render as labels', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.exposureTime, 0),
        'BULB',
      );
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureTime,
          0xFFFFFFFF,
        ),
        'TIME',
      );
    });
  });

  group('PropFormatter.formatValue — aperture', () {
    test('renders as f/N with one decimal when needed', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.fNumber, 280),
        'f/2.8',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.fNumber, 140),
        'f/1.4',
      );
    });

    test('renders whole stops without decimals', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.fNumber, 800),
        'f/8',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.fNumber, 1600),
        'f/16',
      );
    });
  });

  group('PropFormatter.formatValue — exposure bias', () {
    test('zero renders as 0.0', () {
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureBiasCompensation,
          0,
        ),
        '0.0',
      );
    });

    test('positive uses plus sign', () {
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureBiasCompensation,
          700,
        ),
        '+0.7',
      );
    });

    test('negative uses minus sign (U+2212)', () {
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureBiasCompensation,
          -300,
        ),
        '−0.3',
      );
    });
  });

  group('PropFormatter.formatValue — enums', () {
    test('white balance', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.whiteBalance, 0x0002),
        'AUTO',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.whiteBalance, 0x0004),
        'DAYLIGHT',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.whiteBalance, 0x8010),
        'CLOUDY',
      );
    });

    test('exposure program mode', () {
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureProgramMode,
          0x0001,
        ),
        'M',
      );
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureProgramMode,
          0x0004,
        ),
        'S',
      );
      expect(
        PropFormatter.formatValue(
          StandardPropCode.exposureProgramMode,
          0x8050,
        ),
        'U1',
      );
    });

    test('unknown enum value falls back to hex', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.whiteBalance, 0x9999),
        '0x9999',
      );
    });
  });

  group('PropFormatter.formatValue — misc', () {
    test('battery level appends percent sign', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.batteryLevel, 87),
        '87%',
      );
    });

    test('focal length renders millimetres', () {
      expect(
        PropFormatter.formatValue(StandardPropCode.focalLength, 5000),
        '50mm',
      );
      expect(
        PropFormatter.formatValue(StandardPropCode.focalLength, 2450),
        '24.5mm',
      );
    });

    test('unknown prop with int value returns the raw integer as string', () {
      expect(PropFormatter.formatValue(0xABCD, 42), '42');
    });
  });

  test('kCorePropCodes contains the six exposure props', () {
    expect(kCorePropCodes, contains(StandardPropCode.exposureIndex));
    expect(kCorePropCodes, contains(StandardPropCode.exposureTime));
    expect(kCorePropCodes, contains(StandardPropCode.fNumber));
    expect(kCorePropCodes, contains(StandardPropCode.exposureBiasCompensation));
    expect(kCorePropCodes, contains(StandardPropCode.whiteBalance));
    expect(kCorePropCodes, contains(StandardPropCode.focusMode));
  });
}
