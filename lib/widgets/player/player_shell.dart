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
/// 開いている間、動画と曲名行の上に重ねて出す（動画は下で動き続けるが暗くする。
/// 一覧を読むのが優先）。
/// モードごとに違うのは中身だけで、AppBar は透明（`extendBodyBehindAppBar`）にして
/// 背景を上まで通す前提。
///
/// 画面が短くてコントローラーが収まらないときは、動画を 16:9 の [videoMinScale] まで
/// 縮めて（レターボックス）コントローラーを優先する。曲名行とコントローラーの高さは
/// 描画後に測って次のフレームで反映する。
///
/// 横画面（[wide]）は同じ部品を左右に分ける: 左に [topBar]（AppBar の代わり）と動画、
/// 右の脇（幅 [asideMin]〜[asideMax]）に曲名行とコントローラー。[panel] は縦と同じく
/// 動画の上に重ねる（横画面でもコントローラーの高さは変わらないので、脇に入れると溢れる）。
/// 脇が画面より高いとき（波形を開いた小さい端末）は脇だけスクロールする。
class PlayerShell extends ConsumerStatefulWidget {
  const PlayerShell({
    super.key,
    required this.item,
    required this.video,
    required this.header,
    required this.panel,
    required this.controller,
    this.wide = false,
    this.topBar,
  });

  /// 背景の色味に使う（サムネ）
  final LoopItem item;

  /// 動画領域。null なら隠す
  final Widget? video;
  final Widget header;

  /// 中段のパネル。null なら閉じている（空のまま）
  final Widget? panel;
  final Widget controller;

  /// 横画面のレイアウト（左: 動画、右: 曲名行 + コントローラー）
  final bool wide;

  /// [wide] のとき動画の上に出す 1 行（戻る・プレイリスト名・字幕・PiP など）。
  /// 横画面は AppBar を置かないので、その代わり
  final Widget? topBar;

  /// 板や動画の横の余白、画面下端との間
  static const margin = 12.0;

  /// 動画を縮めるときの下限（16:9 の高さに対する割合）
  static const videoMinScale = 0.6;

  /// 横画面の脇（曲名行 + コントローラー）の幅。画面幅の 42% をこの範囲に収める
  static const asideMin = 300.0;
  static const asideMax = 420.0;
  static const asideRatio = 0.42;

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
        if (widget.wide) _buildWide() else _buildTall(),
      ],
    );
  }

  /// 動画を角丸で切り、パネルが被さっている間は暗くする
  Widget? get _clippedVideo => widget.video == null
      ? null
      : ClipRRect(
          borderRadius: AppRadius.borderXl,
          child: _DimWhenCovered(
            dim: widget.panel != null,
            child: widget.video!,
          ),
        );

  /// パネルの出し入れ（縦横共通）。縦に伸ばして置きたいので expand の Stack で切り替える
  Widget _panelSwitcher() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, ?current],
      ),
      child: widget.panel ?? const SizedBox.shrink(key: ValueKey('noPanel')),
    );
  }

  /// 横画面: 左に [PlayerShell.topBar] と動画（パネルはその上に重なる）、右の脇に曲名行と
  /// コントローラー。脇は収まらなければスクロール（コントローラーは下に寄せたまま）
  Widget _buildWide() {
    final mq = MediaQuery.of(context);
    // 横画面は AppBar を置かないので padding.top はステータスバーの分だけ
    final topInset = mq.padding.top;
    final bottomInset = mq.viewPadding.bottom;
    const gap = AppSpacing.lg + 2;
    final video = _clippedVideo;
    return LayoutBuilder(
      builder: (context, constraints) {
        final asideWidth = (constraints.maxWidth * PlayerShell.asideRatio)
            .clamp(PlayerShell.asideMin, PlayerShell.asideMax)
            .toDouble();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: mq.padding.left),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: topInset),
                    if (widget.topBar != null) widget.topBar!,
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (video != null)
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: PlayerShell.margin,
                                    vertical: AppSpacing.sm),
                                child: AspectRatio(
                                    aspectRatio: 16 / 9, child: video),
                              ),
                            ),
                          _panelSwitcher(),
                        ],
                      ),
                    ),
                    Visibility(
                      visible: widget.panel == null,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: const KaraokeSubtitle(),
                    ),
                    SizedBox(height: AppSpacing.xl + bottomInset),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: asideWidth + mq.padding.right,
              child: Padding(
                padding: EdgeInsets.only(right: mq.padding.right),
                child: LayoutBuilder(
                  builder: (context, aside) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: aside.maxHeight),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(height: topInset + AppSpacing.sm + gap),
                            widget.header,
                            const SizedBox(height: gap),
                            const Spacer(),
                            widget.controller,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 縦画面: 動画・曲名行・空き・コントローラーを縦に積む
  Widget _buildTall() {
    return LayoutBuilder(
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

            return Column(
              children: [
                SizedBox(height: topInset + AppSpacing.sm),
                // 上段（動画・字幕・曲名行）の上にパネルを重ねる（開いている間はそれらを隠す）。
                // パネルの下端はコントローラーの上端。コントローラーと同じ Column に入れて
                // おくと、波形の開閉でコントローラーが伸び縮みする途中も毎フレーム追従する
                // （以前は測った高さで Positioned にしていたので、アニメーションの間は
                // 古い高さのまま止まり、終わってから一気に飛んでいた）
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildUpper(gap, videoMax, videoH, measured),
                      _panelSwitcher(),
                    ],
                  ),
                ),
                _MeasureSize(
                  onChange: (s) => setState(() => _controllerHeight = s.height),
                  child: widget.controller,
                ),
              ],
            );
          },
    );
  }

  /// 動画・字幕・曲名行。余りは下に寄せる（Spacer）
  Widget _buildUpper(
      double gap, double videoMax, double videoH, bool measured) {
    final video = _clippedVideo;
    return Column(
              children: [
                if (video != null)
                  if (measured)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: SizedBox(
                        height: videoH,
                        width: videoH * 16 / 9,
                        child: video,
                      ),
                    )
                  else
                    Flexible(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: videoMax),
                          child: AspectRatio(aspectRatio: 16 / 9, child: video),
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
              ],
            );
  }
}

/// パネルに覆われている間、動画を暗くする（一覧を読むのが優先。ぼかしは動画の上では重い）
class _DimWhenCovered extends StatelessWidget {
  const _DimWhenCovered({required this.dim, required this.child});
  final bool dim;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        IgnorePointer(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            color: Colors.black.withValues(alpha: dim ? 0.6 : 0),
          ),
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
