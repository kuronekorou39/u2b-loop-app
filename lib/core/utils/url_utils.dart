class UrlUtils {
  static final _ytRegex = RegExp(
    r'(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/|youtube\.com\/shorts\/|youtube\.com\/live\/)([a-zA-Z0-9_-]{11})',
  );

  static final _playlistRegex = RegExp(
    r'[?&]list=([a-zA-Z0-9_-]+)',
  );

  static String? extractVideoId(String url) {
    final match = _ytRegex.firstMatch(url);
    return match?.group(1);
  }

  static String? extractPlaylistId(String url) {
    final match = _playlistRegex.firstMatch(url);
    return match?.group(1);
  }
}
