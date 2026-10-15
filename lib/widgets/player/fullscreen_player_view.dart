import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_region.dart';
import '../../models/loop_state.dart';
import '../../models/playlist_mode.dart' as pl;
import '../../providers/playlist_player_provider.dart';
import '../../providers/subtitle_provider.dart';
import '../karaoke_subtitle.dart';
import '../loop/loop_panel_parts.dart';
import '../loop/loop_seekbar.dart';
import '../lyrics_overlay.dart';
import 'player_controls.dart';
import 'player_glass_bar.dart';
import 'subtitle_toggle_button.dart';
import 'video_player_widget.dart';

/// 全画面（ボタンで入る。端末の向きだけでは入らない）。
///
/// 動画の上に、タップで出入りするコントロール（上: 曲名 + 字幕切替、下: シークバー +
/// 再生操作）、カラオケ字幕、右から出るドロワー（中身は [drawer]）、解除ボタン。
/// 状態（コントロールの表示・ドロワーの開閉）は画面が持ち、ここは描くだけ
class FullscreenPlayerView extends StatelessWidget {
  const FullscreenPlayerView({
    super.key,
    required this.title,
    required this.bottomInset,
    required this.showOverlay,
    required this.drawerOpen,
    required this.drawer,
    required this.onToggleOverlay,
    required this.onToggleDrawer,
    required this.onExit,
    required this.onSubtitleLongPress,
    required this.onRetryWaveform,
  });

  final String title;
  final double bottomInset;
  final bool showOverlay;
  final bool drawerOpen;
  final Widget drawer;
  final VoidCallback onToggleOverlay;
  final VoidCallback onToggleDrawer;
  final VoidCallback onExit;
  final VoidCallback onSubtitleLongPress;
  final VoidCallback onRetryWaveform;

  /// ドロワーの幅（画面幅に対する割合）
  static const drawerFraction = 0.4;

  @override
  Widget build(BuildContext context) {
    final drawerWidth = MediaQuery.sizeOf(context).width * drawerFraction;
    // immersive中はSafeAreaのpaddingが0になるため、viewPadding(ノッチ/ジェスチャー
    // 領域などの物理インセット)を明示的に使う。最低マージンも確保。
    final vp = MediaQuery.viewPaddingOf(context);
    double atLeast(double v, double m) => v > m ? v : m;
    final padL = atLeast(vp.left, 12);
    final padR = atLeast(vp.right, 12);
    // 開閉タブはコントロール表示に同調（常時表示は邪魔）。ただしドロワーを開いて
    // いる間は閉じられるよう表示し続ける。
    final showToggle = showOverlay || drawerOpen;
    final theme = Theme.of(context);

    return Stack(
      children: [
        // 動画（全画面）+ タップ検知を上に被せる
        const Positioned.fill(
          child: VideoPlayerWidget(useAspectRatio: false),
        ),
        // リリクスオーバーレイ（動画上に重ねる）
        const Positioned.fill(child: LyricsOverlay()),
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
        // オーバーレイ（コントロール）
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: showOverlay ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: !showOverlay,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black54,
                    ],
                    stops: [0.0, 0.2, 0.7, 1.0],
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: padL,
                    right: padR,
                    top: atLeast(vp.top, 8),
                    bottom: atLeast(vp.bottom, 12),
                  ),
                  child: Column(
                    children: [
                      // 上部バー（タイトル + 字幕切替）
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: theme.textTheme.bodyLarge!
                                  .copyWith(color: Colors.white),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SubtitleToggleButton(onLongPress: onSubtitleLongPress),
                        ],
                      ),
                      const Spacer(),
                      // 下部コントロール
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoopSeekbar(
                            compact: true,
                            allowMarkerDrag: false,
                            onRetryWaveform: onRetryWaveform,
                          ),
                          const PlayerControls(),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 字幕（カラオケ）: コントロールの自動非表示に関わらず常時表示。
        // コントロール表示中はシークバーより上、非表示中は画面下寄りに移動。
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          left: padL,
          right: padR,
          bottom: (showOverlay ? 132.0 : 32.0) + bottomInset,
          child: const IgnorePointer(child: KaraokeSubtitle()),
        ),
        // 右ドロワー（半透明）
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
              color: theme.scaffoldBackgroundColor.withValues(alpha: 0.75),
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
        // ドロワー開閉タブ（コントロール表示に同調。右端はノッチ分内側へ）
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
                child: GestureDetector(
                  onTap: onToggleDrawer,
                  child: Container(
                    // 指で掴める幅に（以前は 24px）
                    width: 40,
                    height: 72,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.7),
                      borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(8)),
                    ),
                    child: Icon(
                      drawerOpen ? Icons.chevron_right : Icons.chevron_left,
                      color: Colors.white,
                      size: AppIconSizes.sm,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // フルスクリーン解除ボタン（右下、フルスクリーンボタンと同じ位置）
        if (showOverlay)
          Positioned(
            right: 12 + padR,
            bottom: 12 + vp.bottom,
            child: IconButton(
              onPressed: onExit,
              tooltip: '全画面を解除',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.5),
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 48),
                shape: RoundedRectangleBorder(borderRadius: AppRadius.borderSm),
              ),
              icon: const Icon(Icons.fullscreen_exit, size: AppIconSizes.lg),
            ),
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
    required this.onEdit,
    required this.onExport,
    required this.onSelectAll,
    required this.onSelect,
    required this.onMenu,
    required this.onAdd,
  });

  final List<LoopRegion> regions;

  /// 選択中の区間。-1 は「全体」
  final int activeIndex;
  final LoopState loop;
  final double bottomInset;

  /// null ならループの切り替えは無効（ソースがまだ無い）
  final VoidCallback? onToggleLoop;

  /// 区間を選んでいるときだけ出る「編集」
  final VoidCallback onEdit;

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
              if (activeIndex >= 0)
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
