enum VideoSourceType { youtube, local }

class VideoSource {
  final VideoSourceType type;
  final String uri;
  final String title;
  final String? videoId;
  final String? thumbnailUrl;

  const VideoSource({
    required this.type,
    required this.uri,
    required this.title,
    this.videoId,
    this.thumbnailUrl,
  });
}
