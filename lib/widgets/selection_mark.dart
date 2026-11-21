import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 一覧の行の右端: ふだんは [child]（メニュー・再生ボタンなど）、複数選択中は
/// 同じ場所に選択の印。[child] は隠すだけで場所を残すので、行の中身は動かない
/// （チェックボックスを行の頭に差し込むと、サムネや名前が横にずれた）
class SelectionTrailing extends StatelessWidget {
  const SelectionTrailing({
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
    return Stack(
      alignment: Alignment.centerRight,
      children: [
        Visibility(
          visible: !selecting,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: child,
        ),
        if (selecting)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: AppIconSizes.lg,
              color: selected ? AppTheme.accentGreen : AppTheme.muted(context),
            ),
          ),
      ],
    );
  }
}

/// 一覧の行・カードの中のボタン（⋮・再生など）を包む。ボタンの上を長押ししたときに、
/// ボタンの吹き出し（ツールチップ）を出さず、行・カードの長押し（選択）に回す
/// （吹き出しが長押しを取ってしまい、ボタンの所だけ長押ししても選択に入らなかった）。
/// 吹き出しは出なくなるだけで、読み上げの名前（ツールチップの文）は残る
class ItemInnerButtons extends StatelessWidget {
  const ItemInnerButtons({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TooltipTheme(
        data: TooltipTheme.of(context)
            .copyWith(triggerMode: TooltipTriggerMode.manual),
        child: child,
      );
}

/// 複数選択中、選んでいないものを少し暗くする（どれを選んでいるか一目で分かるように）。
/// 透明度を変えるだけなので大きさ・位置は動かない
class SelectionDim extends StatelessWidget {
  const SelectionDim({
    super.key,
    required this.selecting,
    required this.selected,
    required this.child,
  });

  final bool selecting;
  final bool selected;
  final Widget child;

  static const dimOpacity = 0.45;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: selecting && !selected ? dimOpacity : 1,
      duration: const Duration(milliseconds: 150),
      child: child,
    );
  }
}
