import 'package:meta/meta.dart';

import '../constants/prop_codes.dart';

/// Description of a device property: what values it accepts and how.
///
/// Values are kept generic ([Object]) because the wire type (`dataType`)
/// varies per property — callers use [dataType] to know whether to treat
/// the value as int, string, or a typed list.
@immutable
final class DevicePropDesc {
  const DevicePropDesc({
    required this.propCode,
    required this.dataType,
    required this.getSet,
    required this.factoryDefault,
    required this.currentValue,
    required this.form,
  });

  final int propCode;
  final int dataType;

  /// 0x00 = get, 0x01 = get/set.
  final int getSet;

  final Object? factoryDefault;
  final Object? currentValue;
  final PropForm form;

  bool get isWritable => getSet == 0x01;
}

/// Constrained set of legal values for a property.
sealed class PropForm {
  const PropForm();

  int get flag;
}

final class NoForm extends PropForm {
  const NoForm();

  @override
  int get flag => PtpFormFlag.none;
}

final class RangeForm extends PropForm {
  const RangeForm({
    required this.min,
    required this.max,
    required this.step,
  });

  final Object min;
  final Object max;
  final Object step;

  @override
  int get flag => PtpFormFlag.range;
}

final class EnumForm extends PropForm {
  const EnumForm({required this.values});

  final List<Object> values;

  @override
  int get flag => PtpFormFlag.enumeration;
}
