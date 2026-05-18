import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:hive_flutter/hive_flutter.dart';

import '../app.dart';
import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart' as app;
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';

const _pipChannel = MethodChannel('com.u2bloop/pip');

class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final miniState = ref.watch(miniPlayerProvider);
    if (!miniState.active) return const SizedBox.shrink();

    final controller = ref.watch(videoControllerProvider);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final player = ref.read(playerProvider);

    final progress =
        duration > Duration.zero ? position.inMilliseconds / duration.inMilliseconds : 0.0;

    return GestureDetector(
      onTap: () => _openFullPlayer(ref, miniState),
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: Colors.transparent,
              ),
              SizedBox(
                height: 60,
                child: Row(
                  children: [
                    // 映像
                    SizedBox(
                      width: 96,
                      child: Video(
                        controller: controller,
                        controls: NoVideoControls,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    // タイトル
                    Expanded(
                      child: Text(
                        miniState.item?.title ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    // 再生/停止
                    IconButton(
                      icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        size: AppIconSizes.lg,
                      ),
                      onPressed: () => player.playOrPause(),
                    ),
                    // 閉じる
                    IconButton(
                      icon: const Icon(Icons.close, size: AppIconSizes.md),
                      onPressed: () {
                        player.stop();
                        ref.read(miniPlayerProvider.notifier).deactivate();
                        // 自動PiP無効化 + バックグラウンド再生停止
                        try {
                          _pipChannel.invokeMethod('setAutoPiP', {'enabled': false});
                          _pipChannel.invokeMethod('stopPlaybackService');
                        } catch (_) {}
                        WakelockPlus.disable();
                      },
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                ),
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
      final plBox = Hive.box<app.Playlist>('playlists');
      final itemBox = Hive.box<LoopItem>('loop_items');
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
