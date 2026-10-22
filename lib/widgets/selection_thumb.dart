import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 一覧のサムネに重ねる選択の印（複数選択中だけ）。
/// チェックボックスを行に差し込むとサムネや曲名が横にずれるので、サムネの上に重ねる
class SelectionThumb extends StatelessWidget {
  const SelectionThumb({
    super.key,
    required this.selecting,
    required this.selected,
    required this.child,
  });

  final bool selecting;
  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!selecting) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ColoredBox(
            color: Colors.black.withValues(alpha: selected ? 0.45 : 0.25)),
        Center(
          child: Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            size: AppIconSizes.ml,
            color: selected ? AppTheme.accentGreen : Colors.white70,
          ),
        ),
      ],
    );
  }
}
