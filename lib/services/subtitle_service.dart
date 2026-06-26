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

  /// 字幕エントリをSRT文字列に直列化（オフライン保存用）。
  static String toSrt(List<SubtitleEntry> entries) {
    final sb = StringBuffer();
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      sb.writeln(i + 1);
      sb.writeln('${_srtTime(e.offset)} --> ${_srtTime(e.end)}');
      sb.writeln(e.text);
      sb.writeln();
    }
    return sb.toString();
  }

  static String _srtTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  static final _srtTimeRegex = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})');

  /// 保存したSRTをパースして字幕エントリに戻す（オフライン再生用）。
  static List<SubtitleEntry> parseSrt(String content) {
    final entries = <SubtitleEntry>[];
    final blocks = content.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines =
          block.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      // 時刻行を探す（インデックス行の有無に依存しない）
      int? timeIdx;
      for (var i = 0; i < lines.length; i++) {
        if (_srtTimeRegex.hasMatch(lines[i])) {
          timeIdx = i;
          break;
        }
      }
      if (timeIdx == null) continue;
      final m = _srtTimeRegex.firstMatch(lines[timeIdx])!;
      final start = _srtDuration(m, 1);
      final end = _srtDuration(m, 5);
      final text = lines.sublist(timeIdx + 1).join(' ').trim();
      if (text.isEmpty) continue;
      entries.add(SubtitleEntry(
        text: text,
        offset: start,
        duration: end >= start ? end - start : Duration.zero,
      ));
    }
    return entries;
  }

  static Duration _srtDuration(RegExpMatch m, int g) => Duration(
        hours: int.parse(m.group(g)!),
        minutes: int.parse(m.group(g + 1)!),
        seconds: int.parse(m.group(g + 2)!),
        milliseconds: int.parse(m.group(g + 3)!),
      );

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
