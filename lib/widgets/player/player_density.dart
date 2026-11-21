import 'package:flutter/widgets.dart';

/// 横画面のコントローラーを詰めた形にする（[PlayerShell] の横レイアウトが付ける）
class PlayerDensity extends InheritedWidget {
  const PlayerDensity({
    super.key,
    required this.dense,
    required super.child,
  });

  final bool dense;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerDensity>()?.dense ?? false;

  @override
  bool updateShouldNotify(PlayerDensity old) => old.dense != dense;
}
