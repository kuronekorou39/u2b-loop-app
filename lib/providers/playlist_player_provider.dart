import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/loop_item.dart';
import '../models/playlist_mode.dart';
import '../models/playlist_track.dart';

class PlaylistPlayerState {
  final List<PlaylistTrack> tracks;
  final List<int> playOrder;
  final int currentOrderIndex;
  final RepeatMode repeatMode;
  final bool shuffle;

  const PlaylistPlayerState({
    this.tracks = const [],
    this.playOrder = const [],
    this.currentOrderIndex = 0,
    this.repeatMode = RepeatMode.none,
    this.shuffle = false,
  });

  bool get isEmpty => tracks.isEmpty;
  int get trackCount => tracks.length;
  int get enabledCount => tracks.where((t) => t.enabled).length;

  PlaylistTrack? get currentTrack {
    if (tracks.isEmpty || playOrder.isEmpty) return null;
    if (currentOrderIndex < 0 || currentOrderIndex >= playOrder.length) {
      return null;
    }
    final idx = playOrder[currentOrderIndex];
    if (idx < 0 || idx >= tracks.length) return null;
    return tracks[idx];
  }

  int? get currentTrackIndex {
    if (playOrder.isEmpty ||
        currentOrderIndex < 0 ||
        currentOrderIndex >= playOrder.length) return null;
    return playOrder[currentOrderIndex];
  }

  /// 次のトラックを覗き見（プリロード用）
  PlaylistTrack? peekNext() {
    final idx = peekNextTrackIndex();
    return idx != null ? tracks[idx] : null;
  }

  /// 次のトラックのインデックスを返す（プリロード判定用）
  int? peekNextTrackIndex() {
    final enabledIndices = _enabledOrderIndices;
    if (enabledIndices.isEmpty) return null;

    final currentPos = enabledIndices.indexOf(currentOrderIndex);
    if (currentPos < 0) return null;

    if (currentPos + 1 < enabledIndices.length) {
      return playOrder[enabledIndices[currentPos + 1]];
    }
    if (repeatMode == RepeatMode.all && enabledIndices.isNotEmpty) {
      return playOrder[enabledIndices.first];
    }
    return null;
  }

  List<int> get _enabledOrderIndices {
    final result = <int>[];
    for (var i = 0; i < playOrder.length; i++) {
      if (tracks[playOrder[i]].enabled) result.add(i);
    }
    return result;
  }

  bool get hasNext {
    final enabledIndices = _enabledOrderIndices;
    final currentPos = enabledIndices.indexOf(currentOrderIndex);
    if (currentPos < 0) return false;
    return currentPos + 1 < enabledIndices.length ||
        repeatMode == RepeatMode.all;
  }

  bool get hasPrev {
    final enabledIndices = _enabledOrderIndices;
    final currentPos = enabledIndices.indexOf(currentOrderIndex);
    if (currentPos < 0) return false;
    return currentPos > 0 || repeatMode == RepeatMode.all;
  }

  PlaylistPlayerState copyWith({
    List<PlaylistTrack>? tracks,
    List<int>? playOrder,
    int? currentOrderIndex,
    RepeatMode? repeatMode,
    bool? shuffle,
  }) {
    return PlaylistPlayerState(
      tracks: tracks ?? this.tracks,
      playOrder: playOrder ?? this.playOrder,
      currentOrderIndex: currentOrderIndex ?? this.currentOrderIndex,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
    );
  }
}

final playlistPlayerProvider =
    StateNotifierProvider<PlaylistPlayerNotifier, PlaylistPlayerState>((ref) {
  return PlaylistPlayerNotifier();
});

class PlaylistPlayerNotifier extends StateNotifier<PlaylistPlayerState> {
  PlaylistPlayerNotifier() : super(const PlaylistPlayerState());

  final _random = Random();

  /// プレイリストのアイテムからトラックリストを生成
  /// [regionSelections]: itemId → 選択されたregionIdリスト
  ///   マップに存在しない → 全区間を含める
  ///   空リスト → 0区間（スキップ）
  /// [disabledItemIds]: 無効化されたアイテム（スキップ）
  void loadPlaylist(List<LoopItem> items,
      {int initialItemIndex = 0,
      Map<String, List<String>>? regionSelections,
      Set<String>? disabledItemIds}) {
    final tracks = <PlaylistTrack>[];
    int initialTrackIndex = 0;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];

      // 無効化されたアイテムはスキップ
      if (disabledItemIds != null && disabledItemIds.contains(item.id)) {
        continue;
      }

      final regions = item.effectiveRegions;
      final selectedIds = regionSelections?[item.id];

      // 明示的に0区間が選択されている場合はスキップ
      if (selectedIds != null && selectedIds.isEmpty) continue;

      if (regions.isEmpty || (regions.length == 1 && !regions.first.hasPoints)) {
        // 区間なし: アイテム全体が1トラック
        if (i == initialItemIndex) initialTrackIndex = tracks.length;
        tracks.add(PlaylistTrack(
          item: item,
          itemIndex: i,
        ));
      } else {
        // 区間あり: 選択された区間のみ（未指定なら全区間）
        if (i == initialItemIndex) initialTrackIndex = tracks.length;
        for (var r = 0; r < regions.length; r++) {
          if (selectedIds != null &&
              !selectedIds.contains(regions[r].id)) {
            continue; // この区間は選択されていない
          }
          tracks.add(PlaylistTrack(
            item: item,
            region: regions[r],
            itemIndex: i,
            regionIndex: r,
          ));
        }
      }
    }

    final order = List.generate(tracks.length, (i) => i);
    state = PlaylistPlayerState(
      tracks: tracks,
      playOrder: order,
      currentOrderIndex: order.indexOf(initialTrackIndex),
    );
  }

  /// 次のトラックへ。戻り値: トラックが変わったか
  bool next() {
    if (state.repeatMode == RepeatMode.single) {
      // 単曲リピート: インデックスは変えない（呼び出し側でseekする）
      return false;
    }

    final enabledIndices = state._enabledOrderIndices;
    if (enabledIndices.isEmpty) return false;

    final currentPos = enabledIndices.indexOf(state.currentOrderIndex);
    int nextPos;
    if (currentPos < 0) {
      nextPos = 0;
    } else if (currentPos + 1 < enabledIndices.length) {
      nextPos = currentPos + 1;
    } else if (state.repeatMode == RepeatMode.all) {
      nextPos = 0;
    } else {
      return false; // 最後のトラック、リピートなし
    }

    state = state.copyWith(
        currentOrderIndex: enabledIndices[nextPos]);
    return true;
  }

  /// 前のトラックへ
  bool prev() {
    final enabledIndices = state._enabledOrderIndices;
    if (enabledIndices.isEmpty) return false;

    final currentPos = enabledIndices.indexOf(state.currentOrderIndex);
    int prevPos;
    if (currentPos < 0) {
      prevPos = enabledIndices.length - 1;
    } else if (currentPos > 0) {
      prevPos = currentPos - 1;
    } else if (state.repeatMode == RepeatMode.all) {
      prevPos = enabledIndices.length - 1;
    } else {
      return false;
    }

    state = state.copyWith(
        currentOrderIndex: enabledIndices[prevPos]);
    return true;
  }

  /// 特定のトラックインデックスにジャンプ
  void jumpTo(int trackIndex) {
    final orderIndex = state.playOrder.indexOf(trackIndex);
    if (orderIndex >= 0) {
      state = state.copyWith(currentOrderIndex: orderIndex);
    }
  }

  /// リピートモードを順次切り替え
  void cycleRepeatMode() {
    final next = switch (state.repeatMode) {
      RepeatMode.none => RepeatMode.all,
      RepeatMode.all => RepeatMode.single,
      RepeatMode.single => RepeatMode.none,
    };
    state = state.copyWith(repeatMode: next);
  }

  /// シャッフル切り替え
  void toggleShuffle() {
    final newShuffle = !state.shuffle;
    final currentTrackIdx = state.currentTrackIndex;

    List<int> newOrder;
    int newOrderIndex;

    if (newShuffle) {
      newOrder = List.generate(state.tracks.length, (i) => i);
      newOrder.shuffle(_random);
      // 現在のトラックを先頭に持ってくる
      if (currentTrackIdx != null) {
        newOrder.remove(currentTrackIdx);
        newOrder.insert(0, currentTrackIdx);
      }
      newOrderIndex = 0;
    } else {
      newOrder = List.generate(state.tracks.length, (i) => i);
      newOrderIndex =
          currentTrackIdx != null ? newOrder.indexOf(currentTrackIdx) : 0;
    }

    state = state.copyWith(
      shuffle: newShuffle,
      playOrder: newOrder,
      currentOrderIndex: newOrderIndex,
    );
  }

  /// トラックの有効/無効切り替え
  void toggleTrackEnabled(int trackIndex) {
    if (trackIndex < 0 || trackIndex >= state.tracks.length) return;
    state.tracks[trackIndex].enabled = !state.tracks[trackIndex].enabled;
    // stateの再発行 (トラックリストの参照は同じだがUIを再構築させる)
    state = state.copyWith(tracks: List.from(state.tracks));
  }

  void clear() {
    state = const PlaylistPlayerState();
  }
}
