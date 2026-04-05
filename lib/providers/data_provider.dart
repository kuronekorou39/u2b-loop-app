import 'dart:io';

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
  int _idCounter = 0;

  // プログレッシブディレイ管理（時間経過でリセット）
  int _requestCount = 0;
  DateTime _lastRequestTime = DateTime.now();
  static const _delayResetDuration = Duration(seconds: 30);
  static const _delayMaxMs = 1500;

  /// リクエスト間のディレイを計算。30秒以上空いたらカウンタリセット。
  Duration _nextDelay() {
    final now = DateTime.now();
    if (now.difference(_lastRequestTime) > _delayResetDuration) {
      _requestCount = 0;
    }
    _lastRequestTime = now;
    _requestCount++;
    final ms = (300 + (_requestCount ~/ 10) * 200).clamp(300, _delayMaxMs);
    return Duration(milliseconds: ms);
  }

  String _generateId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

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
  Future<void> addYouTubeAndFetch(String videoId, String originalUrl,
      {String? tagId}) async {
    final id = _generateId();
    final item = LoopItem(
      id: id,
      title: videoId,
      uri: '',
      sourceType: 'youtube',
      videoId: videoId,
      youtubeUrl: originalUrl,
      fetchStatus: 'fetching',
      tagIds: tagId != null ? [tagId] : null,
    );
    await add(item);
    _fetchYouTubeInfo(item);
  }

  /// プレイリスト取り込み時: 既に取得済みの動画情報を使って追加（再取得不要）
  Future<void> addYouTubeWithInfo({
    required String videoId,
    required String title,
    required String originalUrl,
    String? thumbnailUrl,
    String? tagId,
  }) async {
    // 既に登録済みならスキップ
    if (_box.values.any((i) => i.videoId == videoId)) return;

    final id = _generateId();
    String? thumbPath;
    if (thumbnailUrl != null) {
      await Future.delayed(_nextDelay());
      thumbPath = await ThumbnailService().save(id, thumbnailUrl);
    }
    final item = LoopItem(
      id: id,
      title: title,
      uri: '',
      sourceType: 'youtube',
      videoId: videoId,
      youtubeUrl: originalUrl,
      thumbnailUrl: thumbnailUrl,
      thumbnailPath: thumbPath,
      fetchStatus: null, // 取得完了状態
      tagIds: tagId != null ? [tagId] : null,
    );
    await add(item);
  }

  Future<void> _fetchYouTubeInfo(LoopItem item, {int retry = 0}) async {
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
    } on RequestLimitExceededException {
      // レート制限: 最大3回リトライ（待機時間を増やす）
      if (retry < 3) {
        final waitSec = (retry + 1) * 10; // 10s, 20s, 30s
        item.fetchStatus = 'fetching';
        await update(item);
        await Future.delayed(Duration(seconds: waitSec));
        yt.close();
        return _fetchYouTubeInfo(item, retry: retry + 1);
      }
      item.fetchStatus = 'error:レート制限。しばらく待ってからリトライしてください';
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
    final id = _generateId();
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

  /// サムネイルが未取得のアイテムを一括で再取得
  /// [onProgress] が指定された場合、(処理済み, 対象件数) で進捗を通知
  Future<void> repairThumbnails({
    void Function(int done, int total)? onProgress,
  }) async {
    final items = _box.values.toList();
    // 対象件数を先にカウント
    final targets = <LoopItem>[];
    for (final item in items) {
      if (item.thumbnailPath != null &&
          await File(item.thumbnailPath!).exists()) continue;
      if (item.thumbnailUrl != null ||
          (item.sourceType == 'local' && item.uri.isNotEmpty)) {
        targets.add(item);
      }
    }
    if (targets.isEmpty) return;

    var done = 0;
    for (final item in targets) {
      if (item.thumbnailUrl != null) {
        final path =
            await ThumbnailService().save(item.id, item.thumbnailUrl);
        if (path != null) {
          item.thumbnailPath = path;
          await _box.put(item.id, item);
        }
        await Future.delayed(_nextDelay());
      } else if (item.sourceType == 'local' && item.uri.isNotEmpty) {
        try {
          final path =
              await ThumbnailService().generateFromVideo(item.id, item.uri);
          if (path != null) {
            item.thumbnailPath = path;
            await _box.put(item.id, item);
          }
        } catch (_) {}
      }
      done++;
      onProgress?.call(done, targets.length);
      if (done % 5 == 0) _refresh();
    }
    _refresh();
  }

  /// アイテムを複製（新IDで同じ内容のコピーを作成）
  Future<LoopItem> duplicate(LoopItem source) async {
    final id = _generateId();
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

  Future<void> setColor(String id, int colorIndex) async {
    final tag = _box.get(id);
    if (tag != null) {
      tag.colorIndex = colorIndex;
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

  Future<app.Playlist> duplicate(String id) async {
    final src = _box.get(id);
    if (src == null) throw Exception('Playlist not found');
    final newId = DateTime.now().millisecondsSinceEpoch.toString();
    final copy = app.Playlist(
      id: newId,
      name: '${src.name} (コピー)',
      itemIds: List.from(src.itemIds),
      regionSelections: Map.fromEntries(
        src.regionSelections.entries
            .map((e) => MapEntry(e.key, List<String>.from(e.value))),
      ),
      disabledItemIds: Set.from(src.disabledItemIds),
      thumbnailItemId: src.thumbnailItemId,
    );
    await _box.put(newId, copy);
    _refresh();
    return copy;
  }

  Future<void> addItems(String playlistId, List<String> itemIds,
      {Map<String, List<String>>? regions}) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    for (final id in itemIds) {
      if (!pl.itemIds.contains(id)) pl.itemIds.add(id);
    }
    if (regions != null) {
      for (final entry in regions.entries) {
        if (entry.value.isNotEmpty) {
          pl.regionSelections[entry.key] = entry.value;
        }
      }
    }
    await _box.put(playlistId, pl);
    _refresh();
  }

  Future<void> removeItem(String playlistId, String itemId) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    pl.itemIds.remove(itemId);
    pl.regionSelections.remove(itemId);
    await _box.put(playlistId, pl);
    _refresh();
  }

  Future<void> updateRegionSelection(
      String playlistId, String itemId, List<String> regionIds) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    // 空リスト = 0区間選択（スキップ）として保存
    pl.regionSelections[itemId] = regionIds;
    await _box.put(playlistId, pl);
    _refresh();
  }

  Future<void> toggleItemEnabled(String playlistId, String itemId) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    if (pl.disabledItemIds.contains(itemId)) {
      pl.disabledItemIds.remove(itemId);
    } else {
      pl.disabledItemIds.add(itemId);
    }
    await _box.put(playlistId, pl);
    _refresh();
  }

  Future<void> setThumbnailItem(String playlistId, String? itemId) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    pl.thumbnailItemId = itemId;
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
