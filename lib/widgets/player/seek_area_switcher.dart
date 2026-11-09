import 'package:flutter/material.dart';

/// シーク領域の中身の切り替え（ふつうの波形 ⇄ 重ね表示）。フェードしながら、
/// 高さの違いは下端を固定したまま上へ伸び縮みする。
///
/// [AnimatedSwitcher] だけだと、出ていく側と入ってくる側の高い方の大きさに一瞬で
/// 変わる（重ね表示の方が高いので、出す時は上に飛び出し、しまう時はフェードが
/// 終わるまで空きが残った）。ここでは入ってくる側の大きさだけで組み、出ていく側は
/// 下端に重ねて置く。外の [AnimatedSize] がその大きさの変化を滑らかにし、
/// はみ出す分（伸びる途中の入ってくる側の上、縮む途中の出ていく側の上）は切る
class SeekAreaSwitcher extends StatelessWidget {
  const SeekAreaSwitcher({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 250),
  });

  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomCenter,
            clipBehavior: Clip.none,
            children: [
              for (final p in previous)
                Positioned(left: 0, right: 0, bottom: 0, child: p),
              ?current,
            ],
          ),
          child: child,
        ),
      );
}
