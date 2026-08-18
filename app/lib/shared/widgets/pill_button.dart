import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum PillButtonVariant { primary, ghost }

class PillButton extends StatelessWidget {
  const PillButton({
    required this.label,
    required this.onPressed,
    this.variant = PillButtonVariant.primary,
    this.leading,
    this.expand = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final PillButtonVariant variant;
  final Widget? leading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final isPrimary = variant == PillButtonVariant.primary;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 6)],
        Text(
          label,
          style: TextStyle(
            fontWeight: isPrimary ? FontWeight.w600 : FontWeight.w500,
            fontSize: 13,
            letterSpacing: -0.13,
            color: isPrimary ? Colors.black : AppColors.text,
          ),
        ),
      ],
    );
    final box = Material(
      color: isPrimary ? AppColors.accent : AppColors.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.button,
        side: isPrimary
            ? BorderSide.none
            : const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: AppRadius.button,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: child,
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: box) : box;
  }
}
