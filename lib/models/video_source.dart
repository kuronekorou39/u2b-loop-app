enum VideoSourceType { youtube, local }

class VideoSource {
  final VideoSourceType type;
  final String uri;
  final String title;
  final String? videoId;
  final String? thumbnailUrl;
  final String? audioUri; // 波形取得用 audio-only URL（player の muxed URL と分離）

  const VideoSource({
    required this.type,
    required this.uri,
    required this.title,
    this.videoId,
    this.thumbnailUrl,
    this.audioUri,
  });
}
