import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_item.dart';
import '../../providers/thumb_tone_provider.dart';
import '../karaoke_subtitle.dart';

/// 再生画面（縦）の骨組み。プレイリスト再生と単体再生で共通。
///
/// 上から: サムネ色の背景 / 角丸の動画 / 字幕 / 曲名行（[header]）/ 空き /
/// ガラス板のコントローラー（[controller]）。[panel]（トラック一覧・AB 区間）は
/// 開いている間、動画と曲名行の上に重ねて出す（動画は下で動き続ける）。
/// モードごとに違うのは中身だけで、AppBar は透明（`extendBodyBehindAppBar`）にして
/// 背景を上まで通す前提。
///
/// 画面が短くてコントローラーが収まらないときは、動画を 16:9 の [videoMinScale] まで
/// 縮めて（レターボックス）コントローラーを優先する。曲名行とコントローラーの高さは
/// 描画後に測って次のフレームで反映する。
class PlayerShell extends ConsumerStatefulWidget {
  const PlayerShell({
    super.key,
    required this.item,
    required this.video,
    required this.header,
    required this.panel,
    required this.controller,
  });

  /// 背景の色味に使う（サムネ）
  final LoopItem item;

  /// 動画領域。null なら隠す
  final Widget? video;
  final Widget header;

  /// 中段のパネル。null なら閉じている（空のまま）
  final Widget? panel;
  final Widget controller;

  /// 板や動画の横の余白、画面下端との間
  static const margin = 12.0;

  /// 動画を縮めるときの下限（16:9 の高さに対する割合）
  static const videoMinScale = 0.6;

  @override
  ConsumerState<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends ConsumerState<PlayerShell> {
  double _headerHeight = 0;
  double _controllerHeight = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: _ToneBackground(item: widget.item)),
        LayoutBuilder(
          builder: (context, constraints) {
            // extendBodyBehindAppBar なので body 内の padding.top が AppBar の下端
            final topInset = MediaQuery.paddingOf(context).top;
            const gap = AppSpacing.lg + 2;
            final videoMax =
                (constraints.maxWidth - PlayerShell.margin * 2) * 9 / 16;
            final fixed = topInset +
                AppSpacing.sm +
                gap * 2 +
                _headerHeight +
                _controllerHeight;
            final videoH = (constraints.maxHeight - fixed)
                .clamp(videoMax * PlayerShell.videoMinScale, videoMax);
            // 曲名行とコントローラーを測る前の最初のフレームは、溢れないように
            // 伸縮する枠に入れておく（1 フレームだけなので見た目には出ない）
            final measured = _headerHeight > 0 && _controllerHeight > 0;

            return Stack(
              children: [
                _buildColumn(topInset, gap, videoMax, videoH, measured),
                // パネルは動画と曲名行の上に重ねる（開いている間はそれらを隠す）。
                // 下端はコントローラーの上端（コントローラーは測った高さ）
                Positioned(
                  left: 0,
                  right: 0,
                  top: topInset + AppSpacing.sm,
                  bottom: _controllerHeight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    // パネルは縦に伸ばして置きたいので、既定の中央寄せ Stack ではなく expand
                    layoutBuilder: (current, previous) => Stack(
                      fit: StackFit.expand,
                      children: [...previous, ?current],
                    ),
                    child: widget.panel ??
                        const SizedBox.shrink(key: ValueKey('noPanel')),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildColumn(
      double topInset, double gap, double videoMax, double videoH, bool measured) {
    return Column(
              children: [
                SizedBox(height: topInset + AppSpacing.sm),
                if (widget.video != null)
                  if (measured)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: SizedBox(
                        height: videoH,
                        width: videoH * 16 / 9,
                        child: ClipRRect(
                          borderRadius: AppRadius.borderXl,
                          child: widget.video,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: videoMax),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: ClipRRect(
                              borderRadius: AppRadius.borderXl,
                              child: widget.video,
                            ),
                          ),
                        ),
                      ),
                    ),
                // パネルを開いている間、曲名行と字幕はパネルの下に隠れる。
                // 地を透かすので描かない（高さは保ってレイアウトを動かさない）
                Visibility(
                  visible: widget.panel == null,
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: true,
                  child: const KaraokeSubtitle(),
                ),
                SizedBox(height: gap),
                _MeasureSize(
                  onChange: (s) => setState(() => _headerHeight = s.height),
                  child: Visibility(
                    visible: widget.panel == null,
                    maintainState: true,
                    maintainAnimation: true,
                    maintainSize: true,
                    child: widget.header,
                  ),
                ),
                SizedBox(height: gap),
                const Spacer(),
                _MeasureSize(
                  onChange: (s) => setState(() => _controllerHeight = s.height),
                  child: widget.controller,
                ),
              ],
            );
  }
}

/// サムネの色味を薄く敷いた背景。曲が変わるとなめらかに移る
class _ToneBackground extends ConsumerWidget {
  const _ToneBackground({required this.item});
  final LoopItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = item.thumbnailPath;
    final tone =
        path == null ? null : ref.watch(thumbToneProvider(path)).valueOrNull;
    final theme = Theme.of(context);
    final colors = (tone ?? ThumbTone.fallback).gradient(
      theme.scaffoldBackgroundColor,
      dark: theme.brightness == Brightness.dark,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    );
  }
}

/// 子の描画後の大きさを報告する（変わったときだけ）
class _MeasureSize extends StatefulWidget {
  const _MeasureSize({required this.onChange, required this.child});
  final ValueChanged<Size> onChange;
  final Widget child;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  Size? _last;

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = context.size;
      if (size == null || size == _last) return;
      _last = size;
      widget.onChange(size);
    });
    return widget.child;
  }
}
