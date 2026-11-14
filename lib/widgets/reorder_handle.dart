import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 並べ替えのつまみ（≡）。触れた時点で行を持ち上げる。
///
/// 標準の [ReorderableDragStartListener] は指が動くまでドラッグを確定しないので、
/// つまみを押したまま止まっていると行の長押し（複数選択）が先に勝ってしまう。
/// つまみの上では、すぐ動かしても長押ししても並べ替えになるようにする
class ReorderHandle extends ReorderableDragStartListener {
  ReorderHandle({
    super.key,
    required super.index,
    super.enabled,
    EdgeInsetsGeometry padding = const EdgeInsets.all(AppSpacing.sm),
  }) : super(
          child: Builder(
            builder: (context) => Padding(
              padding: padding,
              child: Icon(Icons.drag_handle,
                  size: AppIconSizes.md, color: AppTheme.muted(context)),
            ),
          ),
        );

  /// 見えない当たり判定だけ（行の右端の列をまるごと並べ替えにするとき、行の上に重ねる）。
  /// 見た目の ≡ は [ReorderHandleIcon]
  const ReorderHandle.area({super.key, required super.index, super.enabled})
      : super(
          child: const SizedBox.expand(
              child: ColoredBox(color: Color(0x00000000))),
        );

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      DelayedMultiDragGestureRecognizer(delay: Duration.zero, debugOwner: this);
}

/// つまみの見た目だけ（当たり判定は [ReorderHandle.area] を行に重ねる）
class ReorderHandleIcon extends StatelessWidget {
  const ReorderHandleIcon({super.key});

  /// アイコンの左右の余白
  static const sidePadding = AppSpacing.sm;

  /// 余白を含めた幅
  static const width = AppIconSizes.md + sidePadding * 2;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(sidePadding),
        child: Icon(Icons.drag_handle,
            size: AppIconSizes.md, color: AppTheme.muted(context)),
      );
}
