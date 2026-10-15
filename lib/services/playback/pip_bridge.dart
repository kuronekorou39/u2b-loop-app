import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/native_channels.dart';
import '../../models/loop_item.dart';

/// PiP ウィンドウ・通知のボタンから届く操作
enum PipAction {
  playPause,
  next,
  prev;

  static PipAction? parse(Object? raw) => switch (raw) {
        'playPause' => PipAction.playPause,
        'next' => PipAction.next,
        'prev' => PipAction.prev,
        _ => null,
      };
}

/// ネイティブから届く呼び出しの受け口。使わないものは省略できる
class PipHandlers {
  const PipHandlers({
    this.onPiPChanged,
    this.onAction,
    this.onAudioDeviceChanged,
    this.onAudioNoisy,
    this.getPlayState,
  });

  /// PiP に入った / 出た
  final void Function(bool inPiP)? onPiPChanged;

  /// PiP・通知のボタン
  final Future<void> Function(PipAction action)? onAction;

  /// 出力先が変わった（'speaker' / 'headphone' / 'bluetooth' など）
  final void Function(String device)? onAudioDeviceChanged;

  /// ヘッドホン抜き・Bluetooth 切断（鳴らし続けないよう止める）
  final Future<void> Function()? onAudioNoisy;

  /// ネイティブが「いま再生中か」を聞いてくる
  final bool Function()? getPlayState;
}

/// ネイティブ（MainActivity.kt / PlaybackService.kt）の PiP・バックグラウンド再生通知との橋渡し。
///
/// 送る側は static、受ける側は [listen] に [PipHandlers] を渡す。
/// メソッド名と引数のキーはネイティブと一字一句一致している必要があるので、
/// ここ以外に文字列を書かないこと。送信は失敗しても握りつぶす（PiP 非対応端末・iOS）。
/// [enterPiP] だけは失敗を呼び出し側に伝える（入れなかったことを人に見せるため）
class PipBridge {
  PipBridge._();

  static MethodChannel get _channel => NativeChannels.pip;

  /// 画面を離れたときに自動で PiP に入るか。[item] のサムネを PiP の絵に使う
  static Future<void> setAutoPiP({
    required bool enabled,
    bool isPlaylist = false,
    LoopItem? item,
  }) =>
      _send('setAutoPiP', {
        'enabled': enabled,
        if (enabled) 'isPlaylist': isPlaylist,
        if (enabled) 'thumbnailUrl': item?.thumbnailUrl,
        if (enabled) 'thumbnailPath': item?.thumbnailPath,
      });

  /// PiP ウィンドウの再生/一時停止ボタンの見た目を合わせる
  static Future<void> updatePlayState(bool playing) =>
      _send('updatePiPPlayState', {'playing': playing});

  /// 通知の曲名と再生状態。ネイティブはタイトル未指定だと「再生中」に上書きするので
  /// 曲名は毎回渡す
  static Future<void> updatePlaybackService({
    required String title,
    required bool playing,
    String? thumbnailPath,
  }) =>
      _send('updatePlaybackService', {
        'title': title,
        'playing': playing,
        'thumbnailPath': thumbnailPath,
      });

  /// PiP と通知の両方に再生状態を伝える
  static Future<void> notifyPlayState({required bool playing, LoopItem? item}) =>
      Future.wait([
        updatePlayState(playing),
        updatePlaybackService(
          title: item?.title ?? '再生中',
          playing: playing,
          thumbnailPath: item?.thumbnailPath,
        ),
      ]).then((_) {});

  /// バックグラウンド再生のフォアグラウンドサービスを始める（通知が出る）
  static Future<void> startPlaybackService(LoopItem item) =>
      _send('startPlaybackService', {
        'title': item.title,
        'thumbnailPath': item.thumbnailPath,
      });

  static Future<void> stopPlaybackService() => _send('stopPlaybackService');

  /// いま PiP に入る。入れなければ例外
  static Future<void> enterPiP(LoopItem item) => _channel.invokeMethod('enterPiP', {
        'thumbnailUrl': item.thumbnailUrl,
        'thumbnailPath': item.thumbnailPath,
      });

  /// ネイティブからの呼び出しを受ける。前のハンドラは置き換わる
  static void listen(PipHandlers handlers) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPiPChanged':
          handlers.onPiPChanged?.call(call.arguments as bool);
        case 'onPiPAction':
          final action = PipAction.parse(call.arguments);
          if (action != null) await handlers.onAction?.call(action);
        case 'onAudioDeviceChanged':
          handlers.onAudioDeviceChanged
              ?.call(call.arguments as String? ?? 'speaker');
        case 'onAudioNoisy':
          await handlers.onAudioNoisy?.call();
        case 'getPlayState':
          return handlers.getPlayState?.call() ?? false;
      }
      return null;
    });
  }

  static void stopListening() => _channel.setMethodCallHandler(null);

  static Future<void> _send(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('[PipBridge] $method に失敗: $e');
    }
  }
}
