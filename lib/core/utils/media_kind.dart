/// ファイル名から、映像の無い音楽ファイルかどうかを見分ける。
///
/// Android の content:// は拡張子を持たないので、表示名（タイトル）も合わせて見る
class MediaKind {
  MediaKind._();

  static const audioExtensions = {
    'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus',
  };

  static bool isAudioName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return false;
    return audioExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// [names] のどれかが音楽ファイルの名前なら true
  static bool isAudio(Iterable<String?> names) =>
      names.any((n) => n != null && isAudioName(n));
}
