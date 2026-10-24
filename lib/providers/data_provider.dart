import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/audio/energy_profile.dart';
import '../core/audio/beat_grid.dart';
import '../core/audio/mix_point_detector.dart';
import '../core/audio/silence_detector.dart';
import '../core/constants.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/playlist.dart' as app;
import '../models/tag.dart';
import '../services/cache_service.dart';
import '../services/share_service.dart';
import '../services/thumbnail_service.dart';
import '../services/waveform_cache.dart';
import '../core/storage/app_boxes.dart';
import '../core/utils/id_generator.dart';

// --- LoopItem ---

final loopItemsProvider =
    StateNotifierProvider<LoopItemsNotifier, List<LoopItem>>((ref) {
  return LoopItemsNotifier(AppBoxes.loopItems, ref);
});

class LoopItemsNotifier extends StateNotifier<List<LoopItem>> {
  final Box<LoopItem> _box;
  final Ref _ref;

  // プログレッシブディレイ管理（時間経過でリセット）
  int _requestCount = 0;
  DateTime _lastRequestTime = DateTime.now();
  static const _delayResetDuration = Duration(seconds: 30);
  static const _delayMaxMs = 3000;

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


  LoopItemsNotifier(this._box, this._ref)
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

  /// テンポ/キーの保存。バックグラウンド解析の完了で一覧の並びが変わらないよう
  /// updatedAt は触らない。[markAnalyzed] が false なら手動補正扱い（analyzedAt 据え置き）。
  /// [silence] を渡したときだけ曲頭・曲末の無音も更新する（手動補正では触らない）。
  /// 拍の格子は解析のときに [beatGrid] で置き換える。手動補正では、BPM が倍/半分なら
  /// 格子をその倍率で引き直す（拍の頭と小節頭は動かない。拍の線・小節単位の効果音・
  /// 交差の長さが直る）、それ以外へ変えたら格子を捨てる
  Future<void> saveAnalysis(
    String id, {
    required double? bpm,
    required String? musicalKey,
    bool markAnalyzed = true,
    SilenceInfo? silence,
    BeatGrid? beatGrid,
  }) async {
    final item = _box.get(id);
    if (item == null) return;
    item.bpm = bpm;
    item.musicalKey = musicalKey;
    if (silence != null) {
      item.leadingSilenceMs = silence.leadingMs;
      item.trailingSilenceMs = silence.trailingMs;
    }
    if (markAnalyzed) {
      item.analyzedAt = DateTime.now().millisecondsSinceEpoch;
      item.analysisVersion = LoopItem.currentAnalysisVersion;
      item.beatBpm = beatGrid?.bpm;
      item.beatOffsetMs = beatGrid?.offsetMs;
      item.beatConfidence = beatGrid?.confidence;
      item.downbeatMs = beatGrid?.downbeatMs;
      item.downbeatConfidence = beatGrid?.downbeatConfidence;
    } else {
      final grid = item.beatGrid;
      final octaves = bpm == null || grid == null ? null : _octavesOf(bpm / grid.bpm);
      if (octaves == null) {
        item.beatBpm = null;
        item.beatOffsetMs = null;
        item.downbeatMs = null;
        item.downbeatConfidence = null;
      } else if (octaves != 0) {
        final scaled = grid!.withBpm(grid.bpm * pow(2, octaves),
            anchorMs: grid.barAnchorMs(item.mixInMs?.toDouble()));
        item.beatBpm = scaled.bpm;
        item.beatOffsetMs = scaled.offsetMs;
        item.downbeatMs = scaled.downbeatMs;
      }
    }
    await _box.put(id, item);
    _refresh();
  }

  /// 倍率が 2 の冪（…1/2, 1, 2, 4…）に 2% 以内で近ければその冪（…−1, 0, 1, 2…）、
  /// 近くなければ null
  static int? _octavesOf(double ratio) {
    if (ratio <= 0) return null;
    final octaves = log(ratio) / ln2;
    final k = octaves.round();
    return (octaves - k).abs() < 0.03 ? k : null;
  }

  /// ミックス点（波形から求めたドロップ / アウトロ）の保存。
  /// 再生中にバックグラウンドで決まるので updatedAt は触らない。変化が無ければ書かない
  Future<void> saveMixPoints(String id, MixPoints points, {EnergyProfile? energy}) async {
    final item = _box.get(id);
    if (item == null) return;
    final samePoints = item.mixInMs == points.mixInMs && item.mixOutMs == points.mixOutMs;
    if (samePoints && (energy == null || energy.isEmpty)) return;
    item.mixInMs = points.mixInMs;
    item.mixOutMs = points.mixOutMs;
    if (energy != null && !energy.isEmpty) {
      item.headDb = energy.headDb;
      item.tailDb = energy.tailDb;
      item.endFadeDb = energy.endFadeDb;
      item.dropDb = energy.dropDb;
    }
    await _box.put(id, item);
    _refresh();
  }

  /// 保存されている最新のアイテム（画面が持つ古いコピーではなく）
  LoopItem? byId(String id) => _box.get(id);

  /// 曲全体の大きさ（音量正規化用）。並びが変わらないよう updatedAt は触らない
  Future<void> saveLoudness(String id, double loudnessDb) async {
    final item = _box.get(id);
    if (item == null) return;
    if (item.loudnessDb != null && (item.loudnessDb! - loudnessDb).abs() < 0.1) return;
    item.loudnessDb = loudnessDb;
    await _box.put(id, item);
    _refresh();
  }

  /// 「1番だけ」の範囲（null で自動に戻す）。並びが変わらないよう updatedAt は触らない
  Future<void> saveFirstVerse(String id, {int? aMs, int? bMs}) async {
    final item = _box.get(id);
    if (item == null) return;
    item.firstVerseAMs = aMs;
    item.firstVerseBMs = bMs;
    await _box.put(id, item);
    _refresh();
  }

  Future<void> delete(String id) async {
    // 削除前にオフラインキャッシュのファイルパスを退避して掃除
    final item = _box.get(id);
    await _box.delete(id);
    await ThumbnailService().delete(id);
    await WaveformCache.delete(id);
    if (item != null) {
      await CacheService()
          .deletePaths(item.cachedVideoPath, item.cachedSubtitlePath);
    }
    // プレイリストから孤立参照を除去
    final plBox = AppBoxes.playlists;
    var playlistsChanged = false;
    for (final pl in plBox.values) {
      if (pl.itemIds.remove(id)) {
        pl.regionSelections.remove(id);
        pl.disabledItemIds.remove(id);
        if (pl.thumbnailItemId == id) pl.thumbnailItemId = null;
        await plBox.put(pl.id, pl);
        playlistsChanged = true;
      }
    }
    // box直書きなので、開いているプレイリスト画面に再読込を通知する
    if (playlistsChanged) _ref.read(playlistsProvider.notifier).reload();
    _refresh();
  }

  /// 再生回数を1つ進める。
  ///
  /// 「再生しただけで一覧の並びが変わる」のを避けるため updatedAt は更新せず、
  /// box直書き＋_refresh で表示だけ最新にする。
  /// （直書きのまま通知しないと、一覧の再生回数が古いままになる）
  Future<void> incrementPlayCount(String itemId, int accumulatedPlayMs) async {
    final item = _box.get(itemId);
    if (item == null) return;
    item.playCount++;
    item.accumulatedPlayMs = accumulatedPlayMs;
    await _box.put(item.id, item);
    _refresh();
  }

  /// 曲の長さを保存する（再生開始時・解析前の問い合わせで分かったとき）。
  /// 一覧の並びを変えないよう updatedAt は触らない。変わらなければ書かない
  Future<void> saveDuration(String itemId, int durationMs) async {
    final item = _box.get(itemId);
    if (item == null || durationMs <= 0 || item.durationMs == durationMs) return;
    item.durationMs = durationMs;
    await _box.put(item.id, item);
    _refresh();
  }

  /// 未カウント分の累積再生時間だけを保存する（アプリ終了対策の定期保存）。
  /// 画面に出ない値なので通知はしない（5秒ごとに一覧を再構築しないため）。
  Future<void> saveAccumulatedPlayMs(String itemId, int accumulatedPlayMs) async {
    final item = _box.get(itemId);
    if (item == null || item.accumulatedPlayMs == accumulatedPlayMs) return;
    item.accumulatedPlayMs = accumulatedPlayMs;
    await _box.put(item.id, item);
  }

  /// オフラインキャッシュ情報をアイテムに保存する。
  /// 並び順を変えないよう updatedAt は更新せず box 直書き＋_refresh。
  Future<void> saveCacheInfo(
    String id, {
    required String videoPath,
    String? subtitlePath,
    String? resolution,
    int? sizeBytes,
  }) async {
    final item = _box.get(id);
    if (item == null) return;
    item.cachedVideoPath = videoPath;
    item.cachedSubtitlePath = subtitlePath;
    item.cachedResolution = resolution;
    item.cachedSizeBytes = sizeBytes;
    item.cachedAt = DateTime.now().millisecondsSinceEpoch;
    await _box.put(id, item);
    _refresh();
  }

  /// オフラインキャッシュ（動画・字幕ファイル＋メタ情報）を削除する。
  Future<void> clearCache(String id) async {
    final item = _box.get(id);
    if (item == null) return;
    await CacheService()
        .deletePaths(item.cachedVideoPath, item.cachedSubtitlePath);
    item.cachedVideoPath = null;
    item.cachedSubtitlePath = null;
    item.cachedResolution = null;
    item.cachedSizeBytes = null;
    item.cachedAt = null;
    await _box.put(id, item);
    _refresh();
  }

  /// YouTube動画を即座にリストに追加し、バックグラウンドで情報を取得
  Future<void> addYouTubeAndFetch(String videoId, String originalUrl,
      {String? tagId}) async {
    final id = IdGenerator.next();
    final item = LoopItem(
      id: id,
      title: videoId,
      uri: '',
      sourceType: SourceTypes.youtube,
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

    final id = IdGenerator.next();
    String? thumbPath;
    if (thumbnailUrl != null) {
      await Future.delayed(_nextDelay());
      thumbPath = await ThumbnailService().save(id, thumbnailUrl);
    }
    final item = LoopItem(
      id: id,
      title: title,
      uri: '',
      sourceType: SourceTypes.youtube,
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
    var shouldRetry = false;
    try {
      final video = await yt.videos.get(item.videoId!)
          .timeout(const Duration(seconds: 30));
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
        shouldRetry = true;
      } else {
        item.fetchStatus = 'error:レート制限。しばらく待ってからリトライしてください';
        await update(item);
      }
    } catch (e) {
      item.fetchStatus =
          'error:${e.toString().length > 80 ? e.toString().substring(0, 80) : e}';
      await update(item);
    } finally {
      yt.close();
    }
    if (shouldRetry) {
      await _fetchYouTubeInfo(item, retry: retry + 1);
    }
  }

  Future<void> retryFetch(LoopItem item) async {
    if (item.videoId == null) return;
    item.fetchStatus = 'fetching';
    await update(item);
    _fetchYouTubeInfo(item);
  }

  /// 複数アイテムのYouTube情報をバックグラウンドで順次取得（ディレイ付き）
  void fetchItemsInBackground(List<String> itemIds) async {
    try {
      for (final id in itemIds) {
        final item = _box.get(id);
        if (item == null || item.fetchStatus != 'fetching') continue;
        await _fetchYouTubeInfo(item);
        await Future.delayed(_nextDelay());
      }
    } catch (_) {}
  }

  /// プレイリスト一括追加（サムネイルDLなし・1回のみUI更新）
  Future<List<String>> addYouTubeBatch({
    required List<({String videoId, String title, String url, String? thumbnailUrl})> videos,
    String? tagId,
  }) async {
    final addedIds = <String>[];
    for (final v in videos) {
      if (_box.values.any((i) => i.videoId == v.videoId)) continue;
      final id = IdGenerator.next();
      final item = LoopItem(
        id: id,
        title: v.title,
        uri: '',
        sourceType: SourceTypes.youtube,
        videoId: v.videoId,
        youtubeUrl: v.url,
        thumbnailUrl: v.thumbnailUrl,
        fetchStatus: null,
        tagIds: tagId != null ? [tagId] : null,
      );
      await _box.put(id, item);
      addedIds.add(id);
    }
    if (addedIds.isNotEmpty) _refresh();
    return addedIds;
  }

  /// サムネイルをバックグラウンドでダウンロード
  void downloadThumbnailsInBackground(List<String> itemIds) async {
    for (final id in itemIds) {
      final item = _box.get(id);
      if (item == null || item.thumbnailPath != null || item.thumbnailUrl == null) {
        continue;
      }
      try {
        await Future.delayed(_nextDelay());
        final thumbPath = await ThumbnailService().save(id, item.thumbnailUrl);
        if (thumbPath != null) {
          item.thumbnailPath = thumbPath;
          await update(item);
        }
      } catch (_) {}
    }
  }

  /// ローカルファイルを一括追加（即座にUI反映→サムネは順次バックグラウンド）
  int addLocalFilesSync(List<({String path, String name})> files) {
    final entries = <String, LoopItem>{};
    for (final f in files) {
      final id = IdGenerator.next();
      entries[id] = LoopItem(
        id: id,
        title: f.name,
        uri: f.path,
        sourceType: SourceTypes.local,
      );
    }
    if (entries.isEmpty) return 0;
    _box.putAll(entries);
    _refresh();
    // サムネイルをバックグラウンドで順次生成
    _generateLocalThumbnailsBatch(entries.values.toList());
    return entries.length;
  }

  void _generateLocalThumbnailsBatch(List<LoopItem> items) async {
    for (final item in items) {
      try {
        final thumbPath =
            await ThumbnailService().generateFromVideo(item.id, item.uri);
        if (thumbPath != null) {
          item.thumbnailPath = thumbPath;
          await _box.put(item.id, item);
        }
      } catch (_) {}
    }
    if (items.isNotEmpty) _refresh();
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
          await File(item.thumbnailPath!).exists()) {
        continue;
      }
      if (item.thumbnailUrl != null ||
          (item.isLocal && item.uri.isNotEmpty)) {
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
      } else if (item.isLocal && item.uri.isNotEmpty) {
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
    final id = IdGenerator.next();
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
          .asMap()
          .entries
          .map((e) => LoopRegion(
                id: IdGenerator.next(),
                name: e.value.name,
                pointAMs: e.value.pointAMs,
                pointBMs: e.value.pointBMs,
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
      if (item != null && !item.tagIds.contains(tagId) &&
          item.tagIds.length < AppLimits.maxTagsPerItem) {
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

  /// 共有インポート用: 枠を一括追加してIDリストを返す（1回のみUI更新）
  Future<List<String>> importSharedItems(
      List<ShareItem> sharedItems, Map<String, String> tagNameToId) async {
    final itemIds = <String>[];
    final newItemIds = <String>[];
    for (final si in sharedItems) {
      if (si.videoId.isEmpty) continue;

      final existing =
          _box.values.where((i) => i.videoId == si.videoId).firstOrNull;
      if (existing != null) {
        itemIds.add(existing.id);
        for (final sr in si.regions) {
          if (existing.regions.length >= AppLimits.maxRegions) break;
          if (!existing.regions.any((r) => r.name == sr.name)) {
            existing.regions
                .add(sr.toLoopRegion('${existing.id}_r${existing.regions.length}'));
          }
        }
        for (final tagName in si.tags) {
          if (existing.tagIds.length >= AppLimits.maxTagsPerItem) break;
          final tagId = tagNameToId[tagName];
          if (tagId != null && !existing.tagIds.contains(tagId)) {
            existing.tagIds.add(tagId);
          }
        }
        await _box.put(existing.id, existing);
        continue;
      }

      final id = IdGenerator.next();
      final tagIds =
          si.tags.map((name) => tagNameToId[name]).whereType<String>().toList();
      final regions = si.regions
          .take(AppLimits.maxRegions)
          .toList()
          .asMap()
          .entries
          .map((e) => e.value.toLoopRegion('${id}_r${e.key}'))
          .toList();
      final item = LoopItem(
        id: id,
        title: si.title,
        uri: '',
        sourceType: SourceTypes.youtube,
        videoId: si.videoId,
        youtubeUrl: 'https://youtu.be/${si.videoId}',
        thumbnailUrl: 'https://img.youtube.com/vi/${si.videoId}/hqdefault.jpg',
        fetchStatus: 'fetching',
        tagIds: tagIds,
        regions: regions,
      );
      await _box.put(id, item);
      itemIds.add(id);
      newItemIds.add(id);
    }
    _refresh();
    return itemIds;
  }
}

// --- Tag ---

final tagsProvider = StateNotifierProvider<TagsNotifier, List<Tag>>((ref) {
  return TagsNotifier(AppBoxes.tags);
});

class TagsNotifier extends StateNotifier<List<Tag>> {
  final Box<Tag> _box;

  /// 並び順はユーザーが決める（[reorder]）。曲に付いたタグの表示もこの順に従う
  TagsNotifier(this._box) : super(_sorted(_box)) {
    // 並び順が無いタグ（以前のタグ・共有やバックアップから入ったもの）に今の並びで番号を振る
    if (state.any((t) => t.order == null)) _renumber(state);
  }

  static List<Tag> _sorted(Box<Tag> box) =>
      box.values.toList()..sort(Tag.compare);

  void _refresh() => state = _sorted(_box);

  /// [tags] の並びどおりに 0, 1, 2… を振って保存する
  void _renumber(List<Tag> tags) {
    for (var i = 0; i < tags.length; i++) {
      tags[i].order = i;
    }
    _box.putAll({for (final t in tags) t.id: t});
    state = List.of(tags);
  }

  Future<Tag> create(String name) async {
    final id = IdGenerator.next();
    // 新しいタグは末尾に
    final last = state.map((t) => t.order ?? -1).fold(-1, (a, b) => a > b ? a : b);
    final tag = Tag(id: id, name: name.trim(), order: last + 1);
    await _box.put(id, tag);
    _refresh();
    return tag;
  }

  /// 並べ替え。[newIndex] は動かした後の位置（ReorderableListView の onReorderItem と同じ）
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.length) return;
    final list = List.of(state);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), moved);
    _renumber(list);
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

/// タグフィルター: キー=タグID, 値=true(含む)/false(除外)
final tagFilterProvider = StateProvider<Map<String, bool>>((ref) => {});

// --- Playlist ---

final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<app.Playlist>>((ref) {
  final notifier = PlaylistsNotifier(AppBoxes.playlists,
      items: () => ref.read(loopItemsProvider));
  // 曲（タグ・取得完了・削除）が変わったら、タグで自動に入れるプレイリストの中身を合わせる
  ref.listen<List<LoopItem>>(loopItemsProvider, (_, items) {
    notifier.syncTagItems(items);
  }, fireImmediately: true);
  return notifier;
});

class PlaylistsNotifier extends StateNotifier<List<app.Playlist>> {
  final Box<app.Playlist> _box;

  /// いまの曲一覧（タグで自動に入れる曲を決めるのに使う）
  final List<LoopItem> Function() _items;

  PlaylistsNotifier(this._box, {List<LoopItem> Function()? items})
      : _items = items ?? (() => const []),
        super(_box.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

  /// 自動で入れるタグに合わせて、全プレイリストの中身を直す
  void syncTagItems(List<LoopItem> items) {
    final changed = <String, app.Playlist>{};
    for (final pl in _box.values) {
      if (pl.syncTagItems(items)) changed[pl.id] = pl;
    }
    if (changed.isEmpty) return;
    _box.putAll(changed);
    _refresh();
  }

  /// 自動で入れるタグを設定する（空で解除。タグで入った曲は手で足した曲として残す）
  Future<void> setTags(String playlistId, List<String> tagIds) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    pl.tagIds = List.of(tagIds);
    if (tagIds.isEmpty) {
      // 解除しても今入っている曲は消さない（急に空になるのを避ける）
      pl.tagItemIds.clear();
      pl.excludedItemIds.clear();
    } else {
      pl.syncTagItems(_items());
    }
    await _box.put(playlistId, pl);
    _refresh();
  }

  /// 外した曲（タグに当てはまるのに自動で入れないことにした曲）を戻す
  Future<void> restoreExcluded(String playlistId) async {
    final pl = _box.get(playlistId);
    if (pl == null) return;
    pl.excludedItemIds.clear();
    pl.syncTagItems(_items());
    await _box.put(playlistId, pl);
    _refresh();
  }

  void _refresh() {
    state = _box.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// box を直接書き換えた側から一覧の再読込を促すための入口
  void reload() => _refresh();

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
    final newId = IdGenerator.next();
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
      defaultShuffle: src.defaultShuffle,
      tagIds: List.from(src.tagIds),
      tagItemIds: Set.from(src.tagItemIds),
      excludedItemIds: Set.from(src.excludedItemIds),
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
      // 手で足した曲になる（タグが外れても残す・外した印も消す）
      pl.tagItemIds.remove(id);
      pl.excludedItemIds.remove(id);
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
    pl.tagItemIds.remove(itemId);
    // タグに当てはまる曲は、外したと覚えておかないと次の同期でまた入る
    final item = _items().where((i) => i.id == itemId).firstOrNull;
    if (item != null && pl.matchesTags(item)) pl.excludedItemIds.add(itemId);
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
}
