import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit（libmpv）の音声フィルタ。
///
/// mpv の `af` プロパティに ffmpeg のフィルタ列を書く。1 枚のプレイヤーに付けるフィルタは
/// ここで 1 本の文字列に組み立てる（低音カット / スイープ用ローパス / エコー）。
/// フィルタ列を書き換えるとフィルタグラフが作り直されて音が一瞬途切れる可能性があるので、
/// - 付けるのは鳴らす前か、交差の決まった 1 点（ベーススワップの位置）だけにし、
/// - 連続的に動かすもの（スイープ）はグラフを作り直さず `af-command` でパラメータだけ変える。
/// 実機で確認してから既定オンにすること。
class AudioFilters {
  AudioFilters._();

  /// 低音を切るときのカットオフ（Hz）。キックとベースが主に 40〜150Hz
  static const bassCutHz = 180;

  /// スイープ（ローパス）の開く側と閉じる側のカットオフ（Hz）
  static const sweepOpenHz = 18000.0;
  static const sweepClosedHz = 250.0;

  /// フィルタ列のラベル（af-command の宛先）と、スイープ用ローパスのインスタンス名
  static const _chainLabel = 'u2b';
  static const _sweepInstance = 'lowpass@sweep';

  /// エコーアウト: 1/4 拍相当（250ms）の多段エコーで尾を引かせる
  static const _echo = 'aecho=0.8:0.9:250|500|750|1000:0.5|0.25|0.12|0.06';

  /// [player] のフィルタ列を組み立てて設定する。全部 false なら外す
  static Future<void> apply(
    Player player, {
    bool bassCut = false,
    bool sweep = false,
    bool echo = false,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final parts = <String>[
      if (bassCut) 'highpass=f=$bassCutHz',
      if (sweep) '$_sweepInstance=f=${sweepOpenHz.round()}',
      if (echo) _echo,
    ];
    final af = parts.isEmpty ? '' : '@$_chainLabel:lavfi=[${parts.join(',')}]';
    try {
      await platform.setProperty('af', af);
    } catch (e) {
      debugPrint('[AudioFilters] フィルタの設定に失敗: $e');
    }
  }

  static Future<void> clear(Player player) => apply(player);

  /// スイープのカットオフを動かす（[apply] で sweep を付けた後に使う）。
  /// グラフは作り直さず、ffmpeg の lowpass に frequency コマンドを送る
  static Future<void> setSweep(Player player, double hz) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.command([
        'af-command',
        _chainLabel,
        'frequency',
        hz.round().toString(),
        _sweepInstance,
      ]);
    } catch (e) {
      debugPrint('[AudioFilters] スイープの更新に失敗: $e');
    }
  }

  /// スイープの進み（0 = 開いている、1 = 閉じ切った）→ カットオフ。耳に合わせて対数で動かす
  static double sweepHz(double progress) {
    final p = progress.clamp(0.0, 1.0);
    return exp(log(sweepOpenHz) + (log(sweepClosedHz) - log(sweepOpenHz)) * p);
  }
}
