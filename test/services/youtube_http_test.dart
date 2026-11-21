import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:u2b_loop_app/services/youtube_http.dart';

/// 動画の配信サーバー（googlevideo）の一部は、HEAD に keep-alive と答えながら同じ接続の
/// 次のリクエストには答えずに閉じる。youtube_explode_dart は同じ URL に HEAD を 2 回続けて
/// 送るので、そういうサーバーの動画（S9pj8HZRypA）が「The page needs to be reloaded.」で
/// 再生できなかった。HEAD は接続を使い回さないようにして避ける。
///
/// 本物の接続を使うので testWidgets は使わない（テストのバインディングは HTTP を差し替える）
void main() {
  late ServerSocket server;
  late Uri url;
  var connections = 0;

  setUp(() async {
    connections = 0;
    // 接続の最初のリクエストには keep-alive で答え、2 つめが来たら答えずに閉じる
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      connections++;
      var requests = 0;
      var buffer = '';
      socket.listen((data) {
        buffer += latin1.decode(data);
        while (buffer.contains('\r\n\r\n')) {
          buffer = buffer.substring(buffer.indexOf('\r\n\r\n') + 4);
          requests++;
          if (requests > 1) {
            socket.destroy();
            return;
          }
          socket.add(latin1.encode('HTTP/1.1 200 OK\r\n'
              'Content-Length: 1000\r\n'
              'Connection: keep-alive\r\n\r\n'));
        }
      }, onError: (_) {}, onDone: socket.destroy);
    });
    url = Uri.parse('http://127.0.0.1:${server.port}/videoplayback?itag=18');
  });

  tearDown(() => server.close());

  test('そのままの http クライアントでは 2 回目の HEAD が閉じた接続を使い回して落ちる', () async {
    final client = http.Client();
    addTearDown(client.close);
    expect((await client.head(url)).statusCode, 200);
    await expectLater(
      client.head(url),
      throwsA(isA<http.ClientException>().having((e) => e.message, 'message',
          contains('Connection closed before full header was received'))),
    );
  });

  test('HeadClosingClient なら HEAD を続けて送っても毎回新しい接続で通る', () async {
    final client = HeadClosingClient(http.Client());
    addTearDown(client.close);
    for (var i = 0; i < 3; i++) {
      expect((await client.head(url)).statusCode, 200);
    }
    expect(connections, 3);
  });

  test('GET は接続を使い回せるまま（ダウンロードを遅くしない）', () async {
    final seen = <(String, bool)>[];
    final client = HeadClosingClient(_Recorder(seen));
    await client.get(url);
    await client.head(url);
    expect(seen, [('GET', true), ('HEAD', false)]);
  });
}

/// 送られたリクエストのメソッドと、接続を使い回すかどうかを記録する
class _Recorder extends http.BaseClient {
  _Recorder(this.seen);

  final List<(String, bool)> seen;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add((request.method, request.persistentConnection));
    return http.StreamedResponse(const Stream.empty(), 200, request: request);
  }
}
