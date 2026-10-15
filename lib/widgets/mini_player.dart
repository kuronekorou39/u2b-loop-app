import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app.dart';
import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';
import '../services/playback/pip_bridge.dart';
import 'glass_panel.dart';

/// 画面の下に浮くミニプレイヤー（ガラス板）。
/// 各画面の下端は [reservedHeight] ぶん余白を取る（App が MediaQuery の padding に足す）
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  /// 板の高さ（余白を除く）
  static const height = 60.0;

  /// 板の下の余白（画面下端との間）。システムのインセットはこれに加える
  static const margin = 12.0;

  /// 出ているとき、下の画面が避けるべき高さ
  static const reservedHeight = height + margin * 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final miniState = ref.watch(miniPlayerProvider);
    if (!miniState.active) return const SizedBox.shrink();

    final controller = ref.watch(videoControllerProvider);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final progress = duration > Duration.zero
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return GestureDetector(
      onTap: () => _openFullPlayer(ref, miniState),
      child: GlassPanel(
        radius: 18,
        margin: EdgeInsets.fromLTRB(margin, 0, margin, margin + bottomInset),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
        child: SizedBox(
          height: height - AppSpacing.md * 2,
          child: Row(
            children: [
              // 映像
              ClipRRect(
                borderRadius: AppRadius.borderMd,
                child: SizedBox(
                  width: 72,
                  child: Video(controller: controller, controls: NoVideoControls),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              // タイトル + 進捗
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      miniState.item?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelMedium!
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 再生/停止
              IconButton(
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: AppIconSizes.xl,
                ),
                tooltip: playing ? '一時停止' : '再生',
                onPressed: () => ref.read(playerProvider).playOrPause(),
              ),
              // 閉じる
              IconButton(
                icon: Icon(Icons.close,
                    size: AppIconSizes.md,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6)),
                tooltip: '閉じる',
                onPressed: () {
                  ref.read(playerProvider).stop();
                  ref.read(miniPlayerProvider.notifier).deactivate();
                  // 自動PiP無効化 + バックグラウンド再生停止
                  PipBridge.setAutoPiP(enabled: false);
                  PipBridge.stopPlaybackService();
                  WakelockPlus.disable();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openFullPlayer(WidgetRef ref, MiniPlayerState state) {
    // 遷移前の再生状態を保存（iOS: トランジション中にmpvが自動pauseする）
    final wasPlaying = ref.read(playerProvider).state.playing;
    // ミニプレイヤーUIを消す（Videoウィジェットを除去）
    ref.read(miniPlayerProvider.notifier).deactivateUI(wasPlaying: wasPlaying);

    // プレイリストIDがある場合、Hiveから最新データを取得
    List<LoopItem>? playlistItems = state.playlistItems;
    Map<String, List<String>>? regionSelections = state.regionSelections;
    Set<String>? disabledItemIds = state.disabledItemIds;
    String? playlistName = state.playlistName;

    if (state.playlistId != null) {
      final plBox = AppBoxes.playlists;
      final itemBox = AppBoxes.loopItems;
      final pl = plBox.get(state.playlistId);
      if (pl != null) {
        playlistItems = pl.itemIds
            .map((id) => itemBox.get(id))
            .whereType<LoopItem>()
            .toList();
        regionSelections = pl.regionSelections;
        disabledItemIds = pl.disabledItemIds;
        playlistName = pl.name;
      }
    }

    // navigatorKeyでルート操作（builder外のcontextではNavigatorにアクセスできない）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            item: state.item!,
            playlistItems: playlistItems,
            initialIndex: state.initialIndex,
            regionSelections: regionSelections,
            disabledItemIds: disabledItemIds,
            playlistName: playlistName,
            playlistId: state.playlistId,
          ),
        ),
      );
    });
  }
}
