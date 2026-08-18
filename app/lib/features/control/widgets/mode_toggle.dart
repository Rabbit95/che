import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

class ModeToggleOption<T> {
  const ModeToggleOption({required this.value, required this.label});
  final T value;
  final String label;
}

/// Compact 2-option segmented switch used for Photo/Video and Burst/Single.
class ModeToggle<T> extends StatelessWidget {
  const ModeToggle({
    required this.options,
    required this.current,
    required this.onChanged,
    super.key,
  });

  final List<ModeToggleOption<T>> options;
  final T current;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final opt in options) _button(opt),
        ],
      ),
    );
  }

  Widget _button(ModeToggleOption<T> opt) {
    final active = opt.value == current;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(opt.value),
      child: Container(
        constraints: const BoxConstraints(minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.surface3 : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
        ),
        alignment: Alignment.center,
        child: Text(
          opt.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: active ? AppColors.text : AppColors.text3,
            fontFamilyFallback: AppTypography.monoFontFallback,
          ),
        ),
      ),
    );
  }
}
