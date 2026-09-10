import 'package:flutter/services.dart';

/// ネイティブ(Kotlin/Swift)とやり取りする MethodChannel。
///
/// チャネル名はネイティブ側と一字一句一致していないと無言で失敗するため、
/// 文字列をここ以外に書かないこと（以前は 'com.u2bloop/pip' が3箇所に散っていた）。
class NativeChannels {
  NativeChannels._();

  /// PiP・バックグラウンド再生通知・オーディオデバイス通知
  /// （MainActivity.kt の PIP_CHANNEL）
  static const pip = MethodChannel('com.u2bloop/pip');

  /// AB区間の書き出し・映像音声の結合（MainActivity.kt の EXPORT_CHANNEL）
  static const export = MethodChannel('com.u2bloop/export');

  /// 波形用の振幅抽出（MainActivity.kt の WAVEFORM_CHANNEL）
  static const waveform = MethodChannel('com.u2bloop/waveform');
}
