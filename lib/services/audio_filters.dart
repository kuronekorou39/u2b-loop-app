import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit（libmpv）の音声フィルタ。
///
/// mpv の `af` プロパティに ffmpeg のフィルタを書く。ベーススワップでは
/// 「入ってくる曲の低音を切って重ね、途中で出ていく曲と入れ替える」のに highpass を使う。
/// フィルタの付け外しで音が一瞬途切れる可能性があるので、実機で確認してから既定オンにすること。
class AudioFilters {
  AudioFilters._();

  /// 低音を切るときのカットオフ（Hz）。キックとベースが主に 40〜150Hz
  static const bassCutHz = 180;

  /// 低音カットのオン/オフ。ネイティブでないプレイヤーでは何もしない
  static Future<void> setBassCut(Player player, bool on) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
          'af', on ? 'lavfi=[highpass=f=$bassCutHz]' : '');
    } catch (e) {
      debugPrint('[AudioFilters] 低音カットの設定に失敗: $e');
    }
  }
}
