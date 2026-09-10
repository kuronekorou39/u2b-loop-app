import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/video_source.dart';
import 'youtube_client_info.dart';

/// Androidクライアント + contentCheckOk/racyCheckOk
/// TVクライアントはBot判定されやすいため、Androidベースで警告回避
final _androidContentCheck = YoutubeApiClient({
  'context': {'client': YouTubeClientInfo.context()},
  'contentCheckOk': true,
  'racyCheckOk': true,
}, YouTubeClientInfo.playerEndpoint);

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

  /// 取得済みマニフェストから再生用ストリームURLを選ぶ。
  /// muxed(音声+映像一体)を優先し、無ければvideoOnlyの最高画質にフォールバックする。
  static String pickStreamUrl(StreamManifest manifest) {
    final muxed = manifest.muxed.sortByVideoQuality();
    if (muxed.isNotEmpty) return muxed.last.url.toString();
    final videoOnly = manifest.videoOnly.sortByVideoQuality();
    if (videoOnly.isNotEmpty) return videoOnly.last.url.toString();
    throw Exception('再生可能なストリームがありません');
  }

  /// 再生用ストリームURLを解決する。
  /// [getVideoSource] と違い動画メタデータ(title/サムネ)を取りに行かないので
  /// リクエストが1回少ない。呼び出し側が LoopItem を持っている再生経路向け。
  Future<String> resolveStreamUrl(String videoId) async =>
      pickStreamUrl(await getManifestWithFallback(videoId));

  Future<VideoSource> getVideoSource(String videoId) async {
    final video = await yt.videos.get(videoId).timeout(_networkTimeout);
    final manifest = await getManifestWithFallback(videoId);
    return VideoSource(
      type: VideoSourceType.youtube,
      uri: pickStreamUrl(manifest),
      title: video.title,
      videoId: videoId,
      thumbnailUrl: video.thumbnails.highResUrl,
    );
  }

  void dispose() => yt.close();
}
