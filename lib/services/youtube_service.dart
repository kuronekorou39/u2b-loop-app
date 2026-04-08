import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/video_source.dart';

/// Androidクライアント + contentCheckOk/racyCheckOk
/// TVクライアントはBot判定されやすいため、Androidベースで警告回避
const _androidContentCheck = YoutubeApiClient({
  'context': {
    'client': {
      'clientName': 'ANDROID',
      'clientVersion': '20.10.38',
      'androidSdkVersion': 30,
      'userAgent':
          'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
      'osName': 'Android',
      'osVersion': '11',
    },
  },
  'contentCheckOk': true,
  'racyCheckOk': true,
}, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

class YouTubeService {
  static const _networkTimeout = Duration(seconds: 30);

  final yt = YoutubeExplode();

  /// ストリームマニフェストを取得（コンテンツ警告付き動画にも対応）
  Future<StreamManifest> getManifestWithFallback(String videoId) async {
    try {
      return await yt.videos.streamsClient
          .getManifest(videoId)
          .timeout(_networkTimeout);
    } on VideoUnplayableException {
      // コンテンツ警告等で再生不可の場合、contentCheckOk付きで再試行
      // TVクライアントはBot判定されやすいため、Android+contentCheckOkを使用
      return await yt.videos.streamsClient
          .getManifest(
            videoId,
            ytClients: [_androidContentCheck, YoutubeApiClient.tv],
          )
          .timeout(_networkTimeout);
    }
  }

  Future<VideoSource> getVideoSource(String videoId) async {
    final video = await yt.videos.get(videoId).timeout(_networkTimeout);
    final manifest = await getManifestWithFallback(videoId);

    // Prefer muxed streams (audio+video combined)
    final muxed = manifest.muxed.sortByVideoQuality();
    if (muxed.isNotEmpty) {
      final stream = muxed.last;
      return VideoSource(
        type: VideoSourceType.youtube,
        uri: stream.url.toString(),
        title: video.title,
        videoId: videoId,
        thumbnailUrl: video.thumbnails.highResUrl,
      );
    }

    // Fallback: highest quality video-only stream
    final videoOnly = manifest.videoOnly.sortByVideoQuality();
    if (videoOnly.isNotEmpty) {
      return VideoSource(
        type: VideoSourceType.youtube,
        uri: videoOnly.last.url.toString(),
        title: video.title,
        videoId: videoId,
        thumbnailUrl: video.thumbnails.highResUrl,
      );
    }

    throw Exception('再生可能なストリームが見つかりません');
  }

  void dispose() => yt.close();
}
