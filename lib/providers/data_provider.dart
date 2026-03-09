import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../services/thumbnail_service.dart';

// --- LoopItem ---

final loopItemsProvider =
    StateNotifierProvider<LoopItemsNotifier, List<LoopItem>>((ref) {
  return LoopItemsNotifier(Hive.box<LoopItem>('loop_items'));
});

class LoopItemsNotifier extends StateNotifier<List<LoopItem>> {
  final Box<LoopItem> _box;

  LoopItemsNotifier(this._box)
      : super(_box.values.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));

  void _refresh() {
    state = _box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> add(LoopItem item) async {
    await _box.put(item.id, item);
    _refresh();
  }

  Future<void> update(LoopItem item) async {
    item.updatedAt = DateTime.now();
    await _box.put(item.id, item);
    _refresh();
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    await ThumbnailService().delete(id);
    _refresh();
  }
}

// --- Playlist ---

final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<Playlist>>((ref) {
  return PlaylistsNotifier(Hive.box<Playlist>('playlists'));
});

class PlaylistsNotifier extends StateNotifier<List<Playlist>> {
  final Box<Playlist> _box;

  PlaylistsNotifier(this._box)
      : super(_box.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

  void _refresh() {
    state = _box.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> add(Playlist playlist) async {
    await _box.put(playlist.id, playlist);
    _refresh();
  }

  Future<void> update(Playlist playlist) async {
    await _box.put(playlist.id, playlist);
    _refresh();
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    _refresh();
  }
}
