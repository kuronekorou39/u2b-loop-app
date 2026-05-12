import 'dart:convert';
import 'dart:io';

class SubtitleEntry {
  final String text;
  final Duration offset;
  final Duration duration;
  final List<SubtitlePart> parts;

  SubtitleEntry({
    required this.text,
    required this.offset,
    required this.duration,
    this.parts = const [],
  });

  Duration get end => offset + duration;
}

class SubtitlePart {
  final String text;
  final Duration offset;

  SubtitlePart({required this.text, required this.offset});
}

class SubtitleTrackInfo {
  final String languageCode;
  final String languageName;
  final String baseUrl;

  SubtitleTrackInfo({
    required this.languageCode,
    required this.languageName,
    required this.baseUrl,
  });
}

class SubtitleService {
  /// innertube API で字幕トラック一覧を取得
  static Future<List<SubtitleTrackInfo>> _getCaptionTracks(
      String videoId) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(
          'https://www.youtube.com/youtubei/v1/player?prettyPrint=false'));
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('User-Agent',
          'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
      request.write(jsonEncode({
        'context': {
          'client': {
            'clientName': 'ANDROID',
            'clientVersion': '20.10.38',
            'hl': 'ja',
          },
        },
        'videoId': videoId,
      }));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final captions = json['captions'];
      if (captions == null) return [];
      final renderer = captions['playerCaptionsTracklistRenderer'];
      if (renderer == null) return [];
      final tracks = renderer['captionTracks'] as List? ?? [];

      return tracks.map((ct) {
        final name = ct['name']?['simpleText'] ??
            ct['name']?['runs']?[0]?['text'] ??
            '';
        return SubtitleTrackInfo(
          languageCode: ct['languageCode'] as String? ?? '',
          languageName: name as String,
          baseUrl: ct['baseUrl'] as String? ?? '',
        );
      }).where((t) => t.baseUrl.isNotEmpty).toList();
    } finally {
      client.close();
    }
  }

  /// 字幕XMLを取得してパース（指定トラックの字幕を取得）
  static Future<List<SubtitleEntry>?> fetchTrack(SubtitleTrackInfo track) =>
      _fetchAndParse(track.baseUrl);

  static Future<List<SubtitleEntry>?> _fetchAndParse(String baseUrl) async {
    final client = HttpClient();
    try {
      // srv3形式で取得（<p t="" d="">テキスト</p>）
      final url = baseUrl.contains('fmt=')
          ? baseUrl
          : '$baseUrl&fmt=srv3';
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent',
          'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      if (body.isEmpty) return null;
      return _parseSubtitleXml(body);
    } finally {
      client.close();
    }
  }

  /// 字幕データを取得
  static Future<({
    List<SubtitleEntry>? subs,
    List<SubtitleTrackInfo> tracks,
    String? selectedLanguage,
    String debug,
  })> fetchSubtitles(
    String videoId, {
    String? preferredLanguage,
  }) async {
    try {
      final tracks = await _getCaptionTracks(videoId);
      if (tracks.isEmpty) {
        return (subs: null, tracks: tracks, selectedLanguage: null, debug: 'tracks=0');
      }

      // トラック選択
      SubtitleTrackInfo? selected;
      if (preferredLanguage != null) {
        selected = tracks
            .where((t) => t.languageCode == preferredLanguage)
            .firstOrNull;
      }
      selected ??=
          tracks.where((t) => t.languageCode == 'ja').firstOrNull;
      selected ??=
          tracks.where((t) => t.languageCode == 'en').firstOrNull;
      selected ??= tracks.first;

      final subs = await _fetchAndParse(selected.baseUrl);
      final count = subs?.length ?? 0;
      return (
        subs: (count > 0) ? subs : null,
        tracks: tracks,
        selectedLanguage: selected.languageCode,
        debug: 'selected=${selected.languageCode} captions=$count',
      );
    } catch (e) {
      return (subs: null, tracks: <SubtitleTrackInfo>[], selectedLanguage: null, debug: 'error: $e');
    }
  }

  /// YouTube字幕XML（srv3形式）のパース
  static List<SubtitleEntry> _parseSubtitleXml(String xml) {
    final entries = <SubtitleEntry>[];
    // <p t="ミリ秒" d="ミリ秒">テキスト</p>
    final regex = RegExp(
      r'<p\s+t="(\d+)"\s+d="(\d+)"[^>]*>(.*?)</p>',
      dotAll: true,
    );
    for (final match in regex.allMatches(xml)) {
      final startMs = int.tryParse(match.group(1) ?? '') ?? 0;
      final durMs = int.tryParse(match.group(2) ?? '') ?? 0;
      var text = match.group(3) ?? '';
      // HTMLタグ除去 + エンティティデコード
      text = text
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('\n', ' ')
          .trim();
      if (text.isEmpty) continue;
      entries.add(SubtitleEntry(
        text: text,
        offset: Duration(milliseconds: startMs),
        duration: Duration(milliseconds: durMs),
      ));
    }
    return entries;
  }
}
