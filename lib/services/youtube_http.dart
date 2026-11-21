import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// youtube_explode_dart を作る入口。`YoutubeExplode()` を直に呼ばずにこれを使う
/// （通信のクライアントを [HeadClosingClient] にするため）
YoutubeExplode newYoutubeExplode() => YoutubeExplode(
      httpClient: YoutubeHttpClient(HeadClosingClient(http.Client())),
    );

/// HEAD のあとは接続を使い回さない http クライアント。
///
/// 動画の配信サーバー（googlevideo）の一部は、HEAD に「Connection: keep-alive」と答えながら、
/// 同じ接続に次のリクエストが来ると答えずに閉じる。dart:io はその接続を使い回して
/// 「Connection closed before full header was received」で失敗する（ブラウザや curl は
/// 自動でやり直すので見えない）。youtube_explode_dart は 360p の一体型（itag 18）の長さを
/// HEAD で聞き、すぐに同じ URL へ HEAD を送って使えるかを確かめるので、そういうサーバーの
/// 動画では毎回 2 回目で落ちた。最後に試す TV クライアントも通らず、「The page needs to be
/// reloaded.」と出て再生できなかった（S9pj8HZRypA、2026-11-21）。
/// GET は使い回しても落ちないので、そのまま（ダウンロードは接続を使い回せる）
class HeadClosingClient extends http.BaseClient {
  HeadClosingClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // 「Connection: close」で送り、答えを受け取ったら閉じる（次は新しい接続）
    if (request.method == 'HEAD') request.persistentConnection = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
