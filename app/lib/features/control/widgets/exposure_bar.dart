import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// Values displayed in the bottom exposure strip. Kept as a plain data
/// object so it can be built from a provider snapshot in one line.
class ExposureValues {
  const ExposureValues({
    required this.iso,
    required this.shutter,
    required this.aperture,
    required this.ev,
    required this.wb,
    this.isoHot = false,
  });

  final String iso;
  final String shutter;
  final String aperture;
  final String ev;
  final String wb;
  final bool isoHot;
}

class ExposureBar extends StatelessWidget {
  const ExposureBar({
    required this.values,
    required this.onTap,
    super.key,
  });

  final ExposureValues values;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Pill(label: 'ISO', value: values.iso, hot: values.isoHot),
            _Pill(label: 'SHUTTER', value: values.shutter),
            _Pill(label: 'APERTURE', value: values.aperture),
            _Pill(label: 'EV', value: values.ev),
            _Pill(label: 'WB', value: values.wb),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.value, this.hot = false});

  final String label;
  final String value;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 9,
              color: AppColors.text3,
              letterSpacing: 0.45,
              fontWeight: FontWeight.w600,
              fontFamilyFallback: AppTypography.monoFontFallback,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: hot ? AppColors.warn : AppColors.text,
              fontFamilyFallback: AppTypography.monoFontFallback,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
