import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/playlist.dart' as app;
import '../models/tag.dart';
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

  /// YouTube動画を即座にリストに追加し、バックグラウンドで情報を取得
  Future<void> addYouTubeAndFetch(String videoId, String originalUrl) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final item = LoopItem(
      id: id,
      title: videoId,
      uri: '',
      sourceType: 'youtube',
      videoId: videoId,
      youtubeUrl: originalUrl,
      fetchStatus: 'fetching',
    );
    await add(item);
    _fetchYouTubeInfo(item);
  }

  Future<void> _fetchYouTubeInfo(LoopItem item) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(item.videoId!);
      item.title = video.title;
      item.thumbnailUrl = video.thumbnails.highResUrl;

      final thumbPath =
          await ThumbnailService().save(item.id, item.thumbnailUrl);
      if (thumbPath != null) item.thumbnailPath = thumbPath;

      item.fetchStatus = null;
      await update(item);
    } catch (e) {
      item.fetchStatus =
          'error:${e.toString().length > 80 ? e.toString().substring(0, 80) : e}';
      await update(item);
    } finally {
      yt.close();
    }
  }

  Future<void> retryFetch(LoopItem item) async {
    if (item.videoId == null) return;
    item.fetchStatus = 'fetching';
    await update(item);
    _fetchYouTubeInfo(item);
  }

  Future<void> addLocalFile(String path, String fileName) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final item = LoopItem(
      id: id,
      title: fileName,
      uri: path,
      sourceType: 'local',
    );
    await add(item);

    // バックグラウンドでサムネイル生成
    _generateLocalThumbnail(item);
  }

  Future<void> _generateLocalThumbnail(LoopItem item) async {
    try {
      final thumbPath =
          await ThumbnailService().generateFromVideo(item.id, item.uri);
      if (thumbPath != null) {
        item.thumbnailPath = thumbPath;
        await update(item);
      }
    } catch (_) {}
  }

  /// アイテムを複製（新IDで同じ内容のコピーを作成）
  Future<LoopItem> duplicate(LoopItem source) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final copy = LoopItem(
      id: id,
      title: '${source.title} (コピー)',
      uri: source.uri,
      sourceType: source.sourceType,
      videoId: source.videoId,
      thumbnailUrl: source.thumbnailUrl,
      thumbnailPath: source.thumbnailPath,
      pointAMs: source.pointAMs,
      pointBMs: source.pointBMs,
      speed: source.speed,
      memo: source.memo,
      tagIds: List.from(source.tagIds),
      youtubeUrl: source.youtubeUrl,
      regions: source.regions
          .map((r) => LoopRegion(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: r.name,
                pointAMs: r.pointAMs,
                pointBMs: r.pointBMs,
              ))
          .toList(),
    );
    await add(copy);
    return copy;
  }

  // --- タグ一括操作 ---

  Future<void> addTagToItems(List<String> itemIds, String tagId) async {
    for (final id in itemIds) {
      final item = _box.get(id);
      if (item != null && !item.tagIds.contains(tagId)) {
        item.tagIds.add(tagId);
        await _box.put(id, item);
      }
    }
    _refresh();
  }

  Future<void> removeTagFromItems(List<String> itemIds, String tagId) async {
    for (final id in itemIds) {
      final item = _box.get(id);
      if (item != null) {
        item.tagIds.remove(tagId);
        await _box.put(id, item);
      }
    }
    _refresh();
  }

  Future<void> clearTagsFromItems(List<String> itemIds) async {
    for (final id in itemIds) {
      final item = _box.get(id);
      if (item != null && item.tagIds.isNotEmpty) {
        item.tagIds.clear();
        await _box.put(id, item);
      }
    }
    _refresh();
  }

  /// タグが削除されたとき、全アイテムから除去
  Future<void> removeTagFromAll(String tagId) async {
    for (final item in _box.values) {
      if (item.tagIds.remove(tagId)) {
        await _box.put(item.id, item);
      }
    }
    _refresh();
  }
}

// --- Tag ---

final tagsProvider = StateNotifierProvider<TagsNotifier, List<Tag>>((ref) {
  return TagsNotifier(Hive.box<Tag>('tags'));
});

class TagsNotifier extends StateNotifier<List<Tag>> {
  final Box<Tag> _box;

  TagsNotifier(this._box)
      : super(_box.values.toList()..sort((a, b) => a.name.compareTo(b.name)));

  void _refresh() {
    state = _box.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<Tag> create(String name) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final tag = Tag(id: id, name: name.trim());
    await _box.put(id, tag);
    _refresh();
    return tag;
  }

  Future<void> rename(String id, String newName) async {
    final tag = _box.get(id);
    if (tag != null) {
      tag.name = newName.trim();
      await _box.put(id, tag);
      _refresh();
    }
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    _refresh();
  }
}

// --- タグフィルター ---

final tagFilterProvider = StateProvider<Set<String>>((ref) => {});

// --- Playlist ---

final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<app.Playlist>>((ref) {
  return PlaylistsNotifier(Hive.box<app.Playlist>('playlists'));
});

class PlaylistsNotifier extends StateNotifier<List<app.Playlist>> {
  final Box<app.Playlist> _box;

  PlaylistsNotifier(this._box)
      : super(_box.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

  void _refresh() {
    state = _box.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> add(app.Playlist playlist) async {
    await _box.put(playlist.id, playlist);
    _refresh();
  }

  Future<void> update(app.Playlist playlist) async {
    await _box.put(playlist.id, playlist);
    _refresh();
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    _refresh();
  }

  Future<void> addItems(String playlistId, List<String> itemIds) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    for (final id in itemIds) {
      if (!pl.itemIds.contains(id)) pl.itemIds.add(id);
    }
    await _box.put(playlistId, pl);
    _refresh();
  }

  Future<void> removeItem(String playlistId, String itemId) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    pl.itemIds.remove(itemId);
    await _box.put(playlistId, pl);
    _refresh();
  }

  Future<void> addItemsByTag(
      String playlistId, String tagId, List<LoopItem> allItems) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    for (final item in allItems) {
      if (item.tagIds.contains(tagId) && !pl.itemIds.contains(item.id)) {
        pl.itemIds.add(item.id);
      }
    }
    await _box.put(playlistId, pl);
    _refresh();
  }
}
