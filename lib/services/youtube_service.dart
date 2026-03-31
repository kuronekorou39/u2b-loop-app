import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/video_source.dart';

class YouTubeService {
  final yt = YoutubeExplode();

  /// ストリームマニフェストを取得（コンテンツ警告付き動画にも対応）
  Future<StreamManifest> getManifestWithFallback(String videoId) async {
    try {
      return await yt.videos.streamsClient.getManifest(videoId);
    } on VideoUnplayableException {
      // コンテンツ警告等で再生不可の場合、contentCheckOk付きのTVクライアントで再試行
      return await yt.videos.streamsClient.getManifest(
        videoId,
        ytClients: [YoutubeApiClient.tv],
      );
    }
  }

  Future<VideoSource> getVideoSource(String videoId) async {
    final video = await yt.videos.get(videoId);
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
