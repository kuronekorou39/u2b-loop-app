import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/loop_item.dart';

final miniPlayerProvider =
    StateNotifierProvider<MiniPlayerNotifier, MiniPlayerState>((ref) {
  return MiniPlayerNotifier();
});

class MiniPlayerState {
  final bool active;
  final LoopItem? item;
  final List<LoopItem>? playlistItems;
  final int initialIndex;
  final Map<String, List<String>>? regionSelections;
  final Set<String>? disabledItemIds;
  final String? playlistName;
  final String? playlistId;

  const MiniPlayerState({
    this.active = false,
    this.item,
    this.playlistItems,
    this.initialIndex = 0,
    this.regionSelections,
    this.disabledItemIds,
    this.playlistName,
    this.playlistId,
  });
}

class MiniPlayerNotifier extends StateNotifier<MiniPlayerState> {
  MiniPlayerNotifier() : super(const MiniPlayerState());

  /// PlayerScreenから戻る時: ミニプレイヤーを表示
  void activate({
    required LoopItem item,
    List<LoopItem>? playlistItems,
    int initialIndex = 0,
    Map<String, List<String>>? regionSelections,
    Set<String>? disabledItemIds,
    String? playlistName,
    String? playlistId,
  }) {
    state = MiniPlayerState(
      active: true,
      item: item,
      playlistItems: playlistItems,
      initialIndex: initialIndex,
      regionSelections: regionSelections,
      disabledItemIds: disabledItemIds,
      playlistName: playlistName,
      playlistId: playlistId,
    );
  }

  /// 再生停止時: state全リセット（player.stopは呼び出し側で行う）
  void deactivate() {
    state = const MiniPlayerState();
  }

  /// フルスクリーン復帰時: UIのみ非表示、再生情報は保持（復帰判定用）
  void deactivateUI() {
    state = MiniPlayerState(
      active: false,
      item: state.item,
      playlistItems: state.playlistItems,
      initialIndex: state.initialIndex,
      regionSelections: state.regionSelections,
      disabledItemIds: state.disabledItemIds,
      playlistName: state.playlistName,
      playlistId: state.playlistId,
    );
  }

  /// 復帰完了後: 情報をクリア
  void clearRestoreInfo() {
    if (!state.active) {
      state = const MiniPlayerState();
    }
  }
}
