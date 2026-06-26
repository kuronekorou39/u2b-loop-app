import 'dart:convert';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// プレイリスト取り込み用の軽量な動画情報。
class PlaylistVideoInfo {
  final String id;
  final String title;
  const PlaylistVideoInfo({required this.id, required this.title});

  String get thumbnailLowUrl => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
  String get thumbnailHighUrl => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
}

/// プレイリストのタイトルと動画一覧。
class PlaylistData {
  final String title;
  final List<PlaylistVideoInfo> videos;
  const PlaylistData({required this.title, required this.videos});
}

/// YouTubeプレイリストの動画を取得するサービス。
///
/// youtube_explode_dart 3.1.0 の `playlists.getVideos` は、YouTubeが新しい
/// `lockupViewModel` 形式へ移行したプレイリストの動画を1件も解析できず空を返す
/// （旧 `playlistVideoRenderer` のみ対応）。本サービスは ytInitialData を直接
/// 再帰走査して新旧両形式の動画を拾い、継続トークンでページングする。
/// HTTP層は youtube_explode_dart の [YoutubeHttpClient]（同意Cookie/ヘッダ/
/// リトライ処理込み）を再利用する。
class PlaylistService {
  static const _continuationPageDelay = Duration(milliseconds: 400);
  static const _maxPages = 200; // 暴走防止（最大約2万件）

  static String thumbnailHighUrl(String id) =>
      'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  /// [playlistId] のタイトルと全動画を取得する。
  ///
  /// [onProgress] は取得済み件数が増えるたびに呼ばれる（進捗表示用）。
  /// [isCancelled] が true を返したらページングを中断し取得済み分を返す。
  Future<PlaylistData> fetch(
    String playlistId, {
    bool Function()? isCancelled,
    void Function(int count)? onProgress,
  }) async {
    final http = YoutubeHttpClient();
    try {
      final url =
          'https://www.youtube.com/playlist?list=$playlistId&hl=en&persist_hl=1';
      final raw = await http.getString(Uri.parse(url));
      final data = _extractInitialData(raw);
      if (data == null) return const PlaylistData(title: '', videos: []);

      final title = _playlistTitle(data) ?? '';
      final seen = <String>{};
      final videos = <PlaylistVideoInfo>[];

      _collectVideos(data, seen, videos);
      onProgress?.call(videos.length);

      var token = _continuationToken(data);
      var pages = 0;
      while (token != null && token.isNotEmpty && pages < _maxPages) {
        if (isCancelled?.call() ?? false) break;
        pages++;
        await Future.delayed(_continuationPageDelay);

        final Map<String, dynamic> resp;
        try {
          resp = await http.sendContinuation('browse', token);
        } catch (_) {
          break; // 継続取得に失敗したら取得済み分を返す
        }

        final before = videos.length;
        _collectVideos(resp, seen, videos);
        onProgress?.call(videos.length);

        final next = _continuationToken(resp);
        if (videos.length == before) break; // 新規動画なし＝終端
        if (next == token) break; // トークンが進まない＝終端
        token = next;
      }

      return PlaylistData(title: title, videos: videos);
    } finally {
      http.close();
    }
  }

  // --- パース ---

  static final _initialDataPatterns = [
    RegExp(r'var ytInitialData = (\{.*?\});</script>', dotAll: true),
    RegExp(r'window\["ytInitialData"\]\s*=\s*(\{.*?\});', dotAll: true),
    RegExp(r'ytInitialData\s*=\s*(\{.*?\});', dotAll: true),
  ];

  Map<String, dynamic>? _extractInitialData(String html) {
    for (final p in _initialDataPatterns) {
      final m = p.firstMatch(html);
      if (m != null) {
        try {
          return json.decode(m.group(1)!) as Map<String, dynamic>;
        } catch (_) {
          // パターン不一致で途中まで掴むと壊れたJSONになる。次のパターンへ。
        }
      }
    }
    return null;
  }

  String? _playlistTitle(dynamic data) {
    final t = _at(data, ['metadata', 'playlistMetadataRenderer', 'title']);
    if (t is String && t.isNotEmpty) return t;
    final mf = _at(data, ['microformat', 'microformatDataRenderer', 'title']);
    return mf is String && mf.isNotEmpty ? mf : null;
  }

  /// 新 `lockupViewModel`（動画）と旧 `playlistVideoRenderer` を再帰収集。
  /// JSONの出現順＝プレイリスト順を保つ。コンテナ階層の変化に強い。
  void _collectVideos(
      dynamic node, Set<String> seen, List<PlaylistVideoInfo> out) {
    if (node is Map) {
      final lockup = node['lockupViewModel'];
      if (lockup is Map &&
          lockup['contentType'] == 'LOCKUP_CONTENT_TYPE_VIDEO') {
        final id = lockup['contentId'];
        if (id is String && _isVideoId(id) && seen.add(id)) {
          final title = _at(lockup,
              ['metadata', 'lockupMetadataViewModel', 'title', 'content']);
          out.add(
              PlaylistVideoInfo(id: id, title: title is String ? title : ''));
        }
      }
      final pvr = node['playlistVideoRenderer'];
      if (pvr is Map) {
        final id = pvr['videoId'];
        if (id is String && _isVideoId(id) && seen.add(id)) {
          final title = _runsText(_at(pvr, ['title', 'runs'])) ??
              _at(pvr, ['title', 'simpleText']);
          out.add(
              PlaylistVideoInfo(id: id, title: title is String ? title : ''));
        }
      }
      for (final v in node.values) {
        _collectVideos(v, seen, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectVideos(v, seen, out);
      }
    }
  }

  /// 次ページの継続トークン。新 `continuationItemViewModel` と
  /// 旧 `continuationItemRenderer` の両方に対応。
  String? _continuationToken(dynamic node) {
    if (node is Map) {
      if (node.containsKey('continuationItemRenderer') ||
          node.containsKey('continuationItemViewModel')) {
        final t = _findFirst(node, 'token');
        if (t is String && t.isNotEmpty) return t;
      }
      for (final v in node.values) {
        final t = _continuationToken(v);
        if (t != null) return t;
      }
    } else if (node is List) {
      for (final v in node) {
        final t = _continuationToken(v);
        if (t != null) return t;
      }
    }
    return null;
  }

  static bool _isVideoId(String s) =>
      s.length == 11 && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s);

  static String? _runsText(dynamic runs) {
    if (runs is List) {
      return runs
          .map((r) => r is Map ? r['text'] : null)
          .whereType<String>()
          .join();
    }
    return null;
  }

  static dynamic _at(dynamic node, List<String> path) {
    for (final k in path) {
      if (node is Map && node.containsKey(k)) {
        node = node[k];
      } else {
        return null;
      }
    }
    return node;
  }

  static dynamic _findFirst(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final v in node.values) {
        final r = _findFirst(v, key);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _findFirst(v, key);
        if (r != null) return r;
      }
    }
    return null;
  }
}
