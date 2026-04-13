import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';

/// プレイリスト共有データのエンコード/デコード
class ShareService {
  static const _scheme = 'u2bloop';
  static const _host = 'share';

  /// 共有データ構造
  /// {
  ///   "n": "プレイリスト名",
  ///   "i": [
  ///     {
  ///       "v": "videoId",
  ///       "t": "タイトル",
  ///       "r": [{"n": "サビ", "a": 45000, "b": 78000}],
  ///       "g": ["タグ名1", "タグ名2"]
  ///     }
  ///   ]
  /// }

  /// プレイリストデータをURLにエンコード
  static String encode({
    required String playlistName,
    required List<LoopItem> items,
    required Map<String, String> tagIdToName,
  }) {
    final data = {
      'n': playlistName,
      'i': items.map((item) {
        final map = <String, dynamic>{
          'v': item.videoId,
          't': item.title,
        };
        // AB区間
        final regions = item.regions
            .where((r) => r.hasPoints)
            .map((r) => <String, dynamic>{
                  'n': r.name,
                  if (r.pointAMs != null) 'a': r.pointAMs,
                  if (r.pointBMs != null) 'b': r.pointBMs,
                })
            .toList();
        if (regions.isNotEmpty) map['r'] = regions;
        // タグ（IDではなく名前で共有）
        final tags = item.tagIds
            .map((id) => tagIdToName[id])
            .whereType<String>()
            .toList();
        if (tags.isNotEmpty) map['g'] = tags;
        return map;
      }).toList(),
    };

    final jsonStr = jsonEncode(data);
    final compressed = gzip.encode(utf8.encode(jsonStr));
    final b64 = base64Url.encode(compressed);
    return '$_scheme://$_host/$b64';
  }

  static final _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');

  /// 制御文字を除去してトリムする
  static String _sanitize(String s, int maxLen) {
    final cleaned = s.replaceAll(_controlChars, '').trim();
    return cleaned.length > maxLen ? cleaned.substring(0, maxLen) : cleaned;
  }

  /// URLをデコードして共有データを返す
  static ShareData? decode(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != _scheme || uri.host != _host) return null;

      final b64 = uri.pathSegments.first;
      // 圧縮爆弾対策: base64サイズ上限
      if (b64.length > 50000) return null;

      final compressed = base64Url.decode(b64);
      final jsonStr = utf8.decode(gzip.decode(compressed));
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      final name = _sanitize(
          data['n'] as String? ?? 'Shared Playlist',
          AppLimits.playlistNameMaxLength);

      final items = (data['i'] as List? ?? []).map((j) {
        if (j is! Map<String, dynamic>) return null;
        final m = j;

        final videoId = (m['v'] as String? ?? '').trim();
        if (videoId.isEmpty || videoId.length > 20) return null;

        final title = _sanitize(
            m['t'] as String? ?? '', AppLimits.titleMaxLength);

        final regions = (m['r'] as List? ?? [])
            .take(AppLimits.maxRegions)
            .map((r) {
              if (r is! Map<String, dynamic>) return null;
              return ShareRegion(
                name: _sanitize(
                    r['n'] as String? ?? '区間', AppLimits.regionNameMaxLength),
                pointAMs: r['a'] as int?,
                pointBMs: r['b'] as int?,
              );
            })
            .whereType<ShareRegion>()
            .toList();

        final tags = (m['g'] as List? ?? [])
            .take(AppLimits.maxTagsPerItem)
            .map((t) {
              if (t is! String) return null;
              final s = _sanitize(t, AppLimits.tagNameMaxLength);
              return s.isEmpty ? null : s;
            })
            .whereType<String>()
            .toList();

        return ShareItem(
          videoId: videoId,
          title: title,
          regions: regions,
          tags: tags,
        );
      }).whereType<ShareItem>().toList();

      return ShareData(name: name, items: items);
    } catch (_) {
      return null;
    }
  }

  /// データサイズ（バイト数）を取得。QRコード可能か判定用。
  static int estimateUrlLength({
    required String playlistName,
    required List<LoopItem> items,
    required Map<String, String> tagIdToName,
  }) {
    return encode(
      playlistName: playlistName,
      items: items,
      tagIdToName: tagIdToName,
    ).length;
  }

  /// QRコードに収まるか（約2000文字以内）
  static bool canFitInQr({
    required String playlistName,
    required List<LoopItem> items,
    required Map<String, String> tagIdToName,
  }) {
    return estimateUrlLength(
          playlistName: playlistName,
          items: items,
          tagIdToName: tagIdToName,
        ) <=
        2000;
  }
}

class ShareData {
  final String name;
  final List<ShareItem> items;
  ShareData({required this.name, required this.items});
}

class ShareItem {
  final String videoId;
  final String title;
  final List<ShareRegion> regions;
  final List<String> tags;
  ShareItem({
    required this.videoId,
    required this.title,
    this.regions = const [],
    this.tags = const [],
  });
}

class ShareRegion {
  final String name;
  final int? pointAMs;
  final int? pointBMs;
  ShareRegion({required this.name, this.pointAMs, this.pointBMs});

  LoopRegion toLoopRegion(String id) => LoopRegion(
        id: id,
        name: name,
        pointAMs: pointAMs,
        pointBMs: pointBMs,
      );
}
