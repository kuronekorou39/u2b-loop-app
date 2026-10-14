import 'dart:convert';

import '../core/storage/app_boxes.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/playlist.dart';
import '../models/tag.dart';

/// 読み込み済みのバックアップ
class BackupData {
  const BackupData({
    required this.items,
    required this.playlists,
    required this.tags,
  });

  final List<LoopItem> items;
  final List<Playlist> playlists;
  final List<Tag> tags;
}

/// バックアップ（JSON）の書き出し・読み込み・復元。
///
/// 以前は設定画面に直書きされており、しかも復元が「全データを消去 → 1件ずつ
/// パースして書き込み」の順だったため、途中の1件が壊れていると
/// **既存データは消えたのに一部しか戻らない**状態で終わっていた。
/// ここでは [decode] で全件パースし終えてから [restore] で置き換える。
class BackupService {
  BackupService._();

  /// バックアップ形式のバージョン（互換性を崩す変更をしたら上げる）
  static const formatVersion = 1;

  // ─── 書き出し ───

  /// 現在のデータからバックアップのJSON文字列を作る
  static String encode({
    required List<LoopItem> items,
    required List<Playlist> playlists,
    required List<Tag> tags,
    DateTime? exportedAt,
  }) {
    final data = {
      'version': formatVersion,
      'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
      'items': items.map(itemToJson).toList(),
      'playlists': playlists.map(playlistToJson).toList(),
      'tags': tags.map(tagToJson).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 保存時のファイル名（例: u2b_loop_backup_2026-09-11T10-00-00.json）
  static String fileName([DateTime? now]) {
    final ts = (now ?? DateTime.now())
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return 'u2b_loop_backup_$ts.json';
  }

  // ─── 読み込み ───

  /// JSON文字列を読み込む。**データには一切触れない**。
  /// 形式が壊れていれば [FormatException] を投げる。
  static BackupData decode(String json) {
    final Object? root;
    try {
      root = jsonDecode(json);
    } on FormatException {
      throw const FormatException('バックアップファイルを読み取れません（JSONではありません）');
    }
    if (root is! Map<String, dynamic>) {
      throw const FormatException('バックアップファイルの形式が違います');
    }
    try {
      return BackupData(
        items: _list(root['items']).map(itemFromJson).toList(),
        playlists: _list(root['playlists']).map(playlistFromJson).toList(),
        tags: _list(root['tags']).map(tagFromJson).toList(),
      );
    } on TypeError catch (e) {
      // 必須項目の欠落や型違い。どの項目かはメッセージに出す
      throw FormatException('バックアップの中身が壊れています: $e');
    }
  }

  static List<Map<String, dynamic>> _list(Object? v) =>
      (v as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  // ─── 復元 ───

  /// 読み込み済みのバックアップで全データを置き換える。
  /// 呼び出し側は、この後で各一覧プロバイダーを invalidate すること。
  static Future<void> restore(BackupData data) async {
    final itemBox = AppBoxes.loopItems;
    final plBox = AppBoxes.playlists;
    final tagBox = AppBoxes.tags;

    await itemBox.clear();
    await plBox.clear();
    await tagBox.clear();

    await itemBox.putAll({for (final i in data.items) i.id: i});
    await plBox.putAll({for (final p in data.playlists) p.id: p});
    await tagBox.putAll({for (final t in data.tags) t.id: t});
  }

  // ─── 個別の変換 ───
  //
  // サムネイル画像のパスやオフライン保存したファイルのパスは端末固有なので含めない
  // （復元後にサムネイルは再取得、オフライン動画は保存し直し）。

  static Map<String, dynamic> itemToJson(LoopItem item) => {
        'id': item.id,
        'title': item.title,
        'uri': item.uri,
        'sourceType': item.sourceType,
        'videoId': item.videoId,
        'thumbnailUrl': item.thumbnailUrl,
        'pointAMs': item.pointAMs,
        'pointBMs': item.pointBMs,
        'speed': item.speed,
        'memo': item.memo,
        'createdAt': item.createdAt.toIso8601String(),
        'updatedAt': item.updatedAt.toIso8601String(),
        'fetchStatus': item.fetchStatus,
        'tagIds': item.tagIds,
        'youtubeUrl': item.youtubeUrl,
        'regions': item.regions.map((r) => r.toMap()).toList(),
        'playCount': item.playCount,
        'accumulatedPlayMs': item.accumulatedPlayMs,
        'hasSubtitles': item.hasSubtitles,
        'bpm': item.bpm,
        'musicalKey': item.musicalKey,
        'analyzedAt': item.analyzedAt,
        'analysisVersion': item.analysisVersion,
        'leadingSilenceMs': item.leadingSilenceMs,
        'trailingSilenceMs': item.trailingSilenceMs,
        'mixInMs': item.mixInMs,
        'mixOutMs': item.mixOutMs,
        'beatOffsetMs': item.beatOffsetMs,
        'beatBpm': item.beatBpm,
        'durationMs': item.durationMs,
      };

  static LoopItem itemFromJson(Map<String, dynamic> j) => LoopItem(
        id: j['id'] as String,
        title: j['title'] as String,
        uri: j['uri'] as String,
        sourceType: j['sourceType'] as String,
        videoId: j['videoId'] as String?,
        thumbnailUrl: j['thumbnailUrl'] as String?,
        pointAMs: j['pointAMs'] as int? ?? 0,
        pointBMs: j['pointBMs'] as int? ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
        memo: j['memo'] as String?,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
            DateTime.now(),
        fetchStatus: j['fetchStatus'] as String?,
        tagIds: (j['tagIds'] as List?)?.cast<String>() ?? [],
        youtubeUrl: j['youtubeUrl'] as String?,
        regions: (j['regions'] as List?)
                ?.map((m) =>
                    LoopRegion.fromMap((m as Map).cast<String, dynamic>()))
                .toList() ??
            [],
        playCount: j['playCount'] as int? ?? 0,
        accumulatedPlayMs: j['accumulatedPlayMs'] as int? ?? 0,
        hasSubtitles: j['hasSubtitles'] as bool?,
        bpm: (j['bpm'] as num?)?.toDouble(),
        musicalKey: j['musicalKey'] as String?,
        analyzedAt: j['analyzedAt'] as int?,
        analysisVersion: j['analysisVersion'] as int?,
        leadingSilenceMs: j['leadingSilenceMs'] as int?,
        trailingSilenceMs: j['trailingSilenceMs'] as int?,
        mixInMs: j['mixInMs'] as int?,
        mixOutMs: j['mixOutMs'] as int?,
        beatOffsetMs: (j['beatOffsetMs'] as num?)?.toDouble(),
        beatBpm: (j['beatBpm'] as num?)?.toDouble(),
        durationMs: j['durationMs'] as int?,
      );

  static Map<String, dynamic> playlistToJson(Playlist pl) => {
        'id': pl.id,
        'name': pl.name,
        'itemIds': pl.itemIds,
        'createdAt': pl.createdAt.toIso8601String(),
        'regionSelections': pl.regionSelections,
        'disabledItemIds': pl.disabledItemIds.toList(),
        'thumbnailItemId': pl.thumbnailItemId,
        'defaultShuffle': pl.defaultShuffle,
      };

  static Playlist playlistFromJson(Map<String, dynamic> j) {
    Map<String, List<String>>? regionSel;
    final rawSel = j['regionSelections'];
    if (rawSel != null) {
      regionSel = (rawSel as Map).cast<String, dynamic>().map(
          (k, v) => MapEntry(k, (v as List).cast<String>()));
    }
    return Playlist(
      id: j['id'] as String,
      name: j['name'] as String,
      itemIds: (j['itemIds'] as List?)?.cast<String>() ?? [],
      createdAt:
          DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      regionSelections: regionSel,
      disabledItemIds: (j['disabledItemIds'] as List?)?.cast<String>().toSet(),
      thumbnailItemId: j['thumbnailItemId'] as String?,
      defaultShuffle: j['defaultShuffle'] as bool? ?? false,
    );
  }

  static Map<String, dynamic> tagToJson(Tag tag) => {
        'id': tag.id,
        'name': tag.name,
        'colorIndex': tag.colorIndex,
      };

  static Tag tagFromJson(Map<String, dynamic> j) => Tag(
        id: j['id'] as String,
        name: j['name'] as String,
        colorIndex: j['colorIndex'] as int? ?? 0,
      );
}
