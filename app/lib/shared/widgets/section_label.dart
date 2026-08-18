import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small uppercase mono label used to group content in scroll views.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {this.padding, super.key});

  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ??
          const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Text(text.toUpperCase(), style: AppTypography.sectionLabel),
    );
  }
}
