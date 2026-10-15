import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/native_channels.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/services/playback/pip_bridge.dart';

/// ネイティブとの橋渡し。メソッド名と引数のキーはネイティブ（Kotlin）と一致していないと
/// 無言で失敗するので、送る側の形と、受ける側の振り分けを固定する
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final item = LoopItem(
    id: 'i1',
    title: '曲',
    uri: 'u',
    sourceType: SourceTypes.youtube,
    videoId: 'v',
    thumbnailUrl: 'https://x/t.jpg',
  );

  late List<MethodCall> sent;
  setUp(() {
    sent = [];
    messenger.setMockMethodCallHandler(NativeChannels.pip, (call) async {
      sent.add(call);
      if (call.method == 'enterPiP') throw PlatformException(code: 'no');
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(NativeChannels.pip, null));

  test('setAutoPiP: 有効のときだけサムネとプレイリストかを添える', () async {
    await PipBridge.setAutoPiP(enabled: true, isPlaylist: true, item: item);
    await PipBridge.setAutoPiP(enabled: false);
    expect(sent[0].method, 'setAutoPiP');
    expect(sent[0].arguments, {
      'enabled': true,
      'isPlaylist': true,
      'thumbnailUrl': 'https://x/t.jpg',
      'thumbnailPath': null,
    });
    expect(sent[1].arguments, {'enabled': false});
  });

  test('notifyPlayState は PiP と通知の両方に送り、曲が無ければ「再生中」', () async {
    await PipBridge.notifyPlayState(playing: true, item: null);
    expect(sent.map((c) => c.method),
        ['updatePiPPlayState', 'updatePlaybackService']);
    expect(sent[0].arguments, {'playing': true});
    expect(sent[1].arguments['title'], '再生中');
  });

  test('送信の失敗は握りつぶし、enterPiP だけは投げる', () async {
    await PipBridge.stopPlaybackService(); // 落ちない
    expect(PipBridge.enterPiP(item), throwsA(isA<PlatformException>()));
  });

  test('listen: ネイティブからの呼び出しを振り分ける', () async {
    final log = <String>[];
    PipBridge.listen(PipHandlers(
      onPiPChanged: (v) => log.add('pip:$v'),
      onAction: (a) async => log.add('action:${a.name}'),
      onAudioDeviceChanged: (d) => log.add('device:$d'),
      onAudioNoisy: () async => log.add('noisy'),
      getPlayState: () => true,
    ));
    Future<Object?> call(String method, [Object? args]) async {
      final data = const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, args));
      final reply = await messenger.handlePlatformMessage(
          NativeChannels.pip.name, data, (_) {});
      return reply == null
          ? null
          : const StandardMethodCodec().decodeEnvelope(reply);
    }

    await call('onPiPChanged', true);
    await call('onPiPAction', 'next');
    await call('onPiPAction', 'unknown'); // 知らない操作は無視
    await call('onAudioDeviceChanged', null); // null は speaker
    await call('onAudioNoisy');
    final playing = await call('getPlayState');
    expect(log, ['pip:true', 'action:next', 'device:speaker', 'noisy']);
    expect(playing, isTrue);
    PipBridge.stopListening();
  });
}
