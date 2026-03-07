import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/video_source.dart';

class YouTubeService {
  final _yt = YoutubeExplode();

  Future<VideoSource> getVideoSource(String videoId) async {
    final video = await _yt.videos.get(videoId);
    final manifest = await _yt.videos.streamsClient.getManifest(videoId);

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

  void dispose() => _yt.close();
}
