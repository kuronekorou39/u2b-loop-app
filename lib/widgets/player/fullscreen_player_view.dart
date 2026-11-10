import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_region.dart';
import '../../models/loop_state.dart';
import '../../models/playlist_mode.dart' as pl;
import '../../providers/player_provider.dart';
import '../../providers/playlist_player_provider.dart';
import '../../providers/subtitle_provider.dart';
import '../glass_panel.dart';
import '../karaoke_subtitle.dart';
import '../loop/loop_panel_parts.dart';
import '../loop/loop_seekbar.dart';
import '../lyrics_overlay.dart';
import 'deck_anchor.dart';
import 'mix_deck.dart';
import 'player_controls.dart';
import 'player_glass_bar.dart';
import 'subtitle_toggle_button.dart';
import 'video_player_widget.dart';

/// 全画面（ボタンで入る。端末の向きだけでは入らない）。
///
/// 動画の上に、タップで出入りするコントロールを重ねる。上: 全画面の解除・曲名と
/// 曲の情報・字幕切替。下: ガラスの板にシークバーと再生操作（プレイリストは前後の曲も）。
/// カラオケ字幕は常に出し、右端のつまみからドロワー（中身は [drawer]）。
/// 状態（コントロールの表示・ドロワーの開閉）は画面が持ち、ここは描くだけ
class FullscreenPlayerView extends StatelessWidget {
  const FullscreenPlayerView({
    super.key,
    required this.title,
    this.subtitle = '',
    required this.bottomInset,
    required this.showOverlay,
    this.overlayPinned = false,
    this.onToggleOverlayPin,
    required this.drawerOpen,
    required this.drawer,
    required this.onToggleOverlay,
    required this.onToggleDrawer,
    required this.onExit,
    required this.onSubtitleLongPress,
    required this.onRetryWaveform,
    this.onMore,
    this.onPrev,
    this.onNext,
    this.isPlaylist = false,
    @visibleForTesting this.video,
    this.seekbar,
    @visibleForTesting this.controls,
  });

  final String title;

  /// 曲名の下の 1 行（BPM・キー・n / 全）
  final String subtitle;
  final double bottomInset;
  final bool showOverlay;

  /// コントロールを出したままにする（上の帯のピン。全画面だけで出す）
  final bool overlayPinned;
  final VoidCallback? onToggleOverlayPin;
  final bool drawerOpen;
  final Widget drawer;
  final VoidCallback onToggleOverlay;
  final VoidCallback onToggleDrawer;
  final VoidCallback onExit;
  final VoidCallback onSubtitleLongPress;
  final VoidCallback onRetryWaveform;

  /// 「その他」メニュー（下の板の右端、ピンの隣）。null なら出さない
  final VoidCallback? onMore;

  /// プレイリストの前後の曲（[isPlaylist] のときだけ出す。null なら無効）
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool isPlaylist;

  /// テストで差し替える（media_kit のプレイヤーを作らずに配置を見るため）
  final Widget? video;

  /// 下の板のシークバー。再生画面は普段と同じもの（波形の開閉・DJ）を渡す。
  /// null なら細いバーだけ
  final Widget? seekbar;
  final Widget? controls;

  /// ドロワーの幅（画面幅に対する割合）
  static const drawerFraction = 0.4;

  /// 下の板の高さの目安（測る前。字幕をその上に逃がす）
  static const panelHeight = 132.0;

  /// 下の板の左右の端（反転 / 固定）の幅。真ん中の再生操作が真ん中に来るよう同じ幅
  static const _panelSideWidth = 96.0;

  /// DJ の板の高さを決めるときに空けておく、上の帯（解除・曲名）と再生操作の行の高さ
  static const _topBandReserve = 56.0;
  static const _transportRowReserve = 64.0;

  @override
  Widget build(BuildContext context) {
    final drawerWidth = MediaQuery.sizeOf(context).width * drawerFraction;
    // immersive中はSafeAreaのpaddingが0になるため、viewPadding(ノッチ/ジェスチャー
    // 領域などの物理インセット)を明示的に使う。最低マージンも確保。
    final vp = MediaQuery.viewPaddingOf(context);
    double atLeast(double v, double m) => v > m ? v : m;
    final padL = atLeast(vp.left, AppSpacing.xl);
    final padR = atLeast(vp.right, AppSpacing.xl);
    final padB = atLeast(vp.bottom, AppSpacing.lg);
    // 開閉つまみはコントロール表示に同調（常時表示は邪魔）。ただしドロワーを開いて
    // いる間は閉じられるよう表示し続ける。
    final showToggle = showOverlay || drawerOpen;
    final theme = Theme.of(context);
    const white = Colors.white;
    // DJ の板の置き場所の高さの上限: 上の帯と再生操作の行と板の余白を除いた残り
    final maxDeckHeight = math.max(
        0.0,
        MediaQuery.sizeOf(context).height -
            atLeast(vp.top, AppSpacing.md) -
            _topBandReserve -
            _transportRowReserve -
            AppSpacing.md -
            AppSpacing.xs -
            padB);

    return DeckAnchorScope(
        builder: (context, anchor) =>
            _PanelHeight(builder: (panelKey, panelH) => Stack(
      children: [
        Positioned.fill(
          child: video ?? const VideoPlayerWidget(useAspectRatio: false),
        ),
        // リリクスオーバーレイ（動画上に重ねる）
        // 歌詞（スクロール）の空いた所をタップしてもコントロールを出す（下のタップ検知は
        // 歌詞の間は外すので、これが無いとコントロールが出せず字幕の切替に届かなかった）。
        // 行のタップはその行へのシークが先に取る
        Positioned.fill(
          child: GestureDetector(
            onTap: onToggleOverlay,
            child: const LyricsOverlay(),
          ),
        ),
        // タップ検知レイヤー（リリクス非表示時のみ有効）
        Positioned.fill(
          child: Consumer(builder: (_, ref, _) {
            final mode = ref.watch(subtitleModeProvider);
            if (mode == SubtitleMode.lyrics) return const SizedBox.shrink();
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onToggleOverlay,
              onDoubleTap: onExit,
            );
          }),
        ),
        // コントロール（上の帯と下の板）
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: showOverlay ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: !showOverlay,
              child: Stack(
                children: [
                  // 上の帯: 曲名が動画の明るい所でも読めるよう、上だけ暗くする
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xA6000000), Color(0x00000000)],
                        ),
                      ),
                      padding: EdgeInsets.fromLTRB(
                          padL - AppSpacing.md,
                          atLeast(vp.top, AppSpacing.md),
                          padR,
                          AppSpacing.xxl * 2),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: onExit,
                            tooltip: '全画面を解除',
                            color: white,
                            icon: const Icon(Icons.fullscreen_exit,
                                size: AppIconSizes.lg),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  style: theme.textTheme.titleMedium!.copyWith(
                                      color: white, fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (subtitle.isNotEmpty)
                                  Text(
                                    subtitle,
                                    style: theme.textTheme.labelSmall!.copyWith(
                                        color: white.withValues(alpha: 0.75)),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          IconTheme(
                            data: const IconThemeData(color: white),
                            child: SubtitleToggleButton(
                                onLongPress: onSubtitleLongPress),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 下の板: シークバーと再生操作。動画の上でも読めるよう暗く敷く
                  Positioned(
                    left: padL,
                    right: padR,
                    bottom: padB,
                    // ぼかしは使わない。フェード中は効かず、出しきった瞬間に一気に効いて
                    // 「最後にカクッと濃くなる」ように見えた（動画の上では重さもある）
                    child: SizeChangedLayoutNotifier(
                      key: panelKey,
                      child: GlassPanel(
                      blur: false,
                      scrim: Colors.black.withValues(alpha: 0.5),
                      radius: 18,
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs, AppSpacing.md, AppSpacing.xs, AppSpacing.xs),
                      child: _panelContents(anchor,
                          maxDeckHeight: maxDeckHeight),
                    )),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 字幕（カラオケ）: コントロールの自動非表示に関わらず常時表示。
        // コントロール表示中は下の板より上、非表示中は画面下寄りに移動。
        // 板の高さは波形の開閉で変わるので測った値を使う
        ValueListenableBuilder<double>(
          valueListenable: panelH,
          builder: (_, h, _) => AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: padL,
            right: padR,
            bottom: (showOverlay ? padB + h + AppSpacing.lg : 32.0) + bottomInset,
            child: const IgnorePointer(child: KaraokeSubtitle()),
          ),
        ),
        // ドロワーを開いている間は、外のタップで閉じる（コントロールの出し入れはしない）
        if (drawerOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleDrawer,
            ),
          ),
        // 右ドロワー（ガラス）
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          right: drawerOpen ? 0 : -drawerWidth,
          top: 0,
          bottom: 0,
          width: drawerWidth,
          child: GestureDetector(
            onTap: () {}, // タップ透過防止
            child: Material(
              color: theme.scaffoldBackgroundColor.withValues(alpha: 0.82),
              elevation: 8,
              child: Theme(
                data: theme.copyWith(
                  cardTheme: const CardThemeData(
                    color: Colors.transparent,
                    elevation: 0,
                  ),
                ),
                child: drawer,
              ),
            ),
          ),
        ),
        // ドロワー開閉つまみ（コントロール表示に同調。右端はノッチ分内側へ）。
        // 動画の上で目立ちすぎないよう、暗いガラスの細いつまみ
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          right: drawerOpen ? drawerWidth : vp.right,
          top: 0,
          bottom: 0,
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: showToggle ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !showToggle,
                child: Tooltip(
                  message: drawerOpen ? '閉じる' : '一覧を開く',
                  child: GestureDetector(
                    onTap: onToggleDrawer,
                    child: Container(
                      // 指で掴める幅（見た目は細く、当たり判定は 40px）
                      width: 40,
                      height: 88,
                      alignment: Alignment.centerRight,
                      color: Colors.transparent,
                      child: Container(
                        width: 28,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(14)),
                          border: Border.all(
                              color: white.withValues(alpha: 0.12)),
                        ),
                        child: Icon(
                          drawerOpen ? Icons.chevron_right : Icons.chevron_left,
                          color: white,
                          size: AppIconSizes.ml,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    )));
  }

  /// 下の板の中身。ふだんは上にシークバー、下に反転 / 再生操作 / 固定。
  /// DJ の板を出している間は、シークバーの行の左半分を板の置き場所にし、シークバーは
  /// 右半分へ寄せる（再生操作の行はそのまま）。板を上に浮かせると動画に被り、縮んで
  /// 小さかった。シークバーはいつも同じ位置に置く（作り直されるとデッキを開いた状態が消える）
  Widget _panelContents(DeckAnchorController anchor,
      {required double maxDeckHeight}) {
    final seek = seekbar ??
        LoopSeekbar(
          compact: true,
          allowMarkerDrag: false,
          onRetryWaveform: onRetryWaveform,
        );
    final transport = controls ??
        PlayerControls(
          prevTrack: isPlaylist
              ? IconButton(
                  onPressed: onPrev,
                  tooltip: '前の曲',
                  icon: const Icon(Icons.skip_previous_rounded),
                )
              : null,
          nextTrack: isPlaylist
              ? IconButton(
                  onPressed: onNext,
                  tooltip: '次の曲',
                  icon: const Icon(Icons.skip_next_rounded),
                )
              : null,
        );
    // 左右・上下の反転（全画面では動画の上のボタンに届かない）
    final flips = Row(mainAxisSize: MainAxisSize.min, children: [
      Consumer(builder: (_, ref, _) {
        final on = ref.watch(flipHorizontalProvider);
        return _PanelIcon(
          icon: Icons.flip,
          on: on,
          tooltip: on ? '左右反転を戻す' : '左右反転',
          onPressed: () =>
              ref.read(flipHorizontalProvider.notifier).state = !on,
        );
      }),
      Consumer(builder: (_, ref, _) {
        final on = ref.watch(flipVerticalProvider);
        return _PanelIcon(
          icon: Icons.flip,
          rotate: true,
          on: on,
          tooltip: on ? '上下反転を戻す' : '上下反転',
          onPressed: () => ref.read(flipVerticalProvider.notifier).state = !on,
        );
      }),
    ]);
    // 右端: その他メニュー + コントロールの固定（留めると自動で消えない）
    final pin = Row(mainAxisSize: MainAxisSize.min, children: [
      if (onMore != null)
        _PanelIcon(
          icon: Icons.more_horiz,
          on: false,
          tooltip: 'その他',
          onPressed: onMore!,
        ),
      if (onToggleOverlayPin != null)
        _PanelIcon(
          icon: overlayPinned ? Icons.push_pin : Icons.push_pin_outlined,
          on: overlayPinned,
          tooltip: overlayPinned ? 'コントロールの固定を外す' : 'コントロールを固定する',
          onPressed: onToggleOverlayPin!,
        ),
    ]);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: anchor.open,
          builder: (context, deckOpen, _) =>
              LayoutBuilder(builder: (context, c) {
            final half = c.maxWidth / 2;
            final deckWidth =
                (half - AppSpacing.sm).clamp(0.0, double.infinity);
            // 画面の高さに入りきらなければ低くする（板は置き場所に合わせて縮む）
            final deckHeight = math.min(
              MixDeck.heightFor(deckWidth, max: MixDeck.maxDiscSizeLarge),
              maxDeckHeight,
            );
            anchor.size = Size(deckWidth, deckHeight);
            // シークバーは下に揃える（板の方が高いので、真ん中だと上へ動いていた）
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // DJ の板の置き場所（開くと半分まで伸び、波形は右半分へ寄る）
                AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  width: deckOpen ? half : 0,
                  height: deckOpen ? deckHeight : 0,
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: DeckAnchorTarget(anchor: anchor),
                ),
                Expanded(child: seek),
              ],
            );
          }),
        ),
        // 再生操作の行は DJ を出していても変えない
        Row(
          children: [
            SizedBox(width: _panelSideWidth, child: flips),
            Expanded(child: transport),
            SizedBox(
              width: _panelSideWidth,
              child: Align(alignment: Alignment.centerRight, child: pin),
            ),
          ],
        ),
      ],
    );
  }
}

/// 全画面ドロワー（プレイリスト）の上の 1 行: シャッフル・リピート・前・n / 全・次・その他。
/// 1番だけ・AB 編集・音量正規化は「その他」シート（縦と同じ）へ。
/// 以前は 8 個並べていてドロワーの幅（画面の 40%）から溢れていた
class FullscreenPlaylistControls extends ConsumerWidget {
  const FullscreenPlaylistControls({
    super.key,
    required this.onShuffle,
    required this.onRepeat,
    required this.onPrev,
    required this.onNext,
    required this.onMore,
  });

  /// null なら無効（プリロード中のシャッフル）
  final VoidCallback? onShuffle;
  final VoidCallback onRepeat;

  /// null なら無効（曲の切り替え中）。前後の曲が無いときもここで無効にする
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final plState = ref.watch(playlistPlayerProvider);
    final currentIdx = plState.currentTrackIndex;

    final (repeatIcon, repeatOn) = switch (plState.repeatMode) {
      pl.RepeatMode.none => (Icons.repeat, false),
      pl.RepeatMode.all => (Icons.repeat, true),
      pl.RepeatMode.single => (Icons.repeat_one, true),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      child: Row(
        children: [
          ToggleIconButton(
            icon: Icons.shuffle,
            on: plState.shuffle,
            onPressed: onShuffle,
            tooltip: 'シャッフル',
          ),
          ToggleIconButton(
            icon: repeatIcon,
            on: repeatOn,
            onPressed: onRepeat,
            tooltip: switch (plState.repeatMode) {
              pl.RepeatMode.none => 'リピートなし',
              pl.RepeatMode.all => '全曲リピート',
              pl.RepeatMode.single => '1曲リピート',
            },
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous, size: AppIconSizes.xl),
            onPressed: plState.hasPrev ? onPrev : null,
            tooltip: '前の曲',
          ),
          Expanded(
            child: Text(
              currentIdx != null
                  ? '${currentIdx + 1} / ${plState.trackCount}'
                  : '- / ${plState.trackCount}',
              style: textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, size: AppIconSizes.xl),
            onPressed: plState.hasNext ? onNext : null,
            tooltip: '次の曲',
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, size: AppIconSizes.ml),
            onPressed: onMore,
            tooltip: 'その他',
          ),
        ],
      ),
    );
  }
}

/// 全画面ドロワー（単体再生）: ループ ON/OFF・編集・書出しの行 + 区間の一覧。
/// AB 編集はここではせず、全画面を解除して横レイアウト（縦と同じ部品）で行うので、
/// [onEdit] と [onAdd] は呼ぶ側で全画面を解除してから続ける
class FullscreenRegionDrawer extends StatelessWidget {
  const FullscreenRegionDrawer({
    super.key,
    required this.regions,
    required this.activeIndex,
    required this.loop,
    required this.bottomInset,
    required this.onToggleLoop,
    this.onEdit,
    required this.onExport,
    required this.onSelectAll,
    required this.onSelect,
    required this.onMenu,
    this.onAdd,
  });

  final List<LoopRegion> regions;

  /// 選択中の区間。-1 は「全体」
  final int activeIndex;
  final LoopState loop;
  final double bottomInset;

  /// null ならループの切り替えは無効（ソースがまだ無い）
  final VoidCallback? onToggleLoop;

  /// 区間を選んでいるときだけ出る「編集」。null なら出さない（全画面では出さない）
  final VoidCallback? onEdit;

  /// 書き出し。A・B が揃っていなければ全体として呼ぶ
  final void Function({required bool fullTrack}) onExport;
  final VoidCallback onSelectAll;
  final void Function(int index) onSelect;
  final void Function(int index) onMenu;

  /// null なら「区間追加」を出さない（上限）
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final divider = Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          child: Row(
            children: [
              ToggleIconButton(
                icon: Icons.repeat,
                on: loop.enabled,
                onPressed: onToggleLoop,
                tooltip: loop.enabled ? 'ループ ON' : 'ループ OFF',
              ),
              const Spacer(),
              if (activeIndex >= 0 && onEdit != null)
                TextButton.icon(
                  onPressed: onEdit,
                  icon: Icon(Icons.edit_outlined,
                      size: AppIconSizes.sm, color: dim),
                  label: const Text('編集'),
                ),
              IconButton(
                onPressed: () => onExport(fullTrack: !loop.hasBothPoints),
                icon: const Icon(Icons.file_download_outlined,
                    size: AppIconSizes.ml),
                tooltip: '書き出し',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md,
                bottomInset + AppSpacing.xxl),
            children: [
              RegionTile(
                name: '全体',
                isActive: activeIndex == -1,
                pointAMs: null,
                pointBMs: null,
                onTap: onSelectAll,
              ),
              divider,
              for (var i = 0; i < regions.length; i++) ...[
                RegionTile(
                  name: regions[i].name,
                  isActive: i == activeIndex,
                  pointAMs: regions[i].pointAMs,
                  pointBMs: regions[i].pointBMs,
                  onTap: () => onSelect(i),
                  onLongPress: () => onMenu(i),
                  onMenu: () => onMenu(i),
                ),
                if (i < regions.length - 1) divider,
              ],
              const SizedBox(height: AppSpacing.sm),
              if (onAdd != null)
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add, size: AppIconSizes.xs),
                    label: const Text('区間追加'),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: theme.dividerColor),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 全画面の下の板の左右の端に置く小さなボタン（反転・固定）。オンは緑
class _PanelIcon extends StatelessWidget {
  const _PanelIcon({
    required this.icon,
    required this.on,
    required this.tooltip,
    required this.onPressed,
    this.rotate = false,
  });

  final IconData icon;
  final bool on;
  final String tooltip;
  final VoidCallback onPressed;

  /// 90 度回す（上下反転のアイコン）
  final bool rotate;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, size: AppIconSizes.md);
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      color: on ? AppTheme.accentGreen : Colors.white,
      icon: rotate ? RotatedBox(quarterTurns: 1, child: glyph) : glyph,
    );
  }
}

/// 全画面の下の板の高さを測って渡す（波形の開閉で変わる。字幕をその上に逃がす）
class _PanelHeight extends StatefulWidget {
  const _PanelHeight({required this.builder});

  final Widget Function(GlobalKey panelKey, ValueListenable<double> height)
      builder;

  @override
  State<_PanelHeight> createState() => _PanelHeightState();
}

class _PanelHeightState extends State<_PanelHeight> {
  final _key = GlobalKey();
  final _height = ValueNotifier(FullscreenPlayerView.panelHeight);

  @override
  void dispose() {
    _height.dispose();
    super.dispose();
  }

  void _measure() {
    final h = _key.currentContext?.size?.height;
    if (mounted && h != null && (h - _height.value).abs() > 0.5) {
      _height.value = h;
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    // 板の大きさが変わるたび（波形の開閉のアニメーション中も）測り直す
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return false;
      },
      child: widget.builder(_key, _height),
    );
  }
}
