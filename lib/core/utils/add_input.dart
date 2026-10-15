import 'url_utils.dart';

/// 「追加」ダイアログに入力された文字列の種類。
/// 判定だけをここに置き（純粋関数）、何をするかは画面側で決める
sealed class AddInput {
  const AddInput();

  static AddInput parse(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return const AddInputEmpty();
    if (url.startsWith('u2bloop://')) return AddInputShare(url);
    final videoId = UrlUtils.extractVideoId(url);
    final playlistId = UrlUtils.extractPlaylistId(url);
    if (videoId == null && playlistId != null) {
      return AddInputPlaylist(playlistId);
    }
    if (videoId != null && playlistId != null) {
      return AddInputVideoInPlaylist(
          videoId: videoId, playlistId: playlistId, url: url);
    }
    if (videoId != null) return AddInputVideo(videoId: videoId, url: url);
    return const AddInputInvalid();
  }
}

class AddInputEmpty extends AddInput {
  const AddInputEmpty();
}

/// アプリの共有 URL（u2bloop://）
class AddInputShare extends AddInput {
  const AddInputShare(this.url);
  final String url;
}

/// プレイリストだけ（動画 ID なし）
class AddInputPlaylist extends AddInput {
  const AddInputPlaylist(this.playlistId);
  final String playlistId;
}

/// 動画 + プレイリスト（どちらを足すか聞く）
class AddInputVideoInPlaylist extends AddInput {
  const AddInputVideoInPlaylist(
      {required this.videoId, required this.playlistId, required this.url});
  final String videoId;
  final String playlistId;
  final String url;
}

class AddInputVideo extends AddInput {
  const AddInputVideo({required this.videoId, required this.url});
  final String videoId;
  final String url;
}

class AddInputInvalid extends AddInput {
  const AddInputInvalid();
}
