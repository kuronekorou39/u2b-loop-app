import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/theme/app_theme.dart';

/// 選択式のボタンの選択中は緑系。エラーと同じ赤（secondary）にしない
void main() {
  for (final (name, theme) in [('ダーク', AppTheme.dark), ('ライト', AppTheme.light)]) {
    test('$name: 選択中は accent、未選択は透明', () {
      final style = theme.segmentedButtonTheme.style!;
      const selected = {WidgetState.selected};
      final accent = theme.colorScheme.primary;
      expect(style.foregroundColor!.resolve(selected), accent);
      expect(style.iconColor!.resolve(selected), accent);
      expect(style.backgroundColor!.resolve(selected), accent.withValues(alpha: 0.22));
      expect(style.backgroundColor!.resolve(const {}), Colors.transparent);
      expect(style.backgroundColor!.resolve(selected),
          isNot(theme.colorScheme.secondary));
    });
  }
}
