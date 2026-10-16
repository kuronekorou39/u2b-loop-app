import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit（libmpv）の音声フィルタ。
///
/// mpv の `af` プロパティに ffmpeg のフィルタ列を書く。フィルタ列を書き換えると
/// フィルタグラフが作り直されて音が一瞬途切れるので、v1.95 からは
/// **低音シェルフ（ベーススワップ用）とローパス（スイープ用）を曲を開くときから付けっぱなし**にし、
/// 交差中は `af-command` で値だけ動かす（gain / frequency はランタイム変更に対応している）。
/// エコー（aecho）だけはランタイム変更に対応していないので、付けるときだけグラフを作り直す。
///
/// `af-command <label> <command> <argument> [<target>]`: label は mpv 側のラベル（@u2b）、
/// target は lavfi グラフの中のインスタンス名（bass@b など）。lavfi フィルタでのみ動く。
class AudioFilters {
  AudioFilters._();

  /// 低音シェルフの中心周波数（Hz）。キックとベースが主に 40〜150Hz
  static const bassHz = 180;

  /// 低音を切ったときのシェルフのゲイン（dB）
  static const bassCutDb = -18.0;

  /// スイープ（ローパス）の開く側と閉じる側のカットオフ（Hz）
  static const sweepOpenHz = 18000.0;
  static const sweepClosedHz = 250.0;

  static const _chainLabel = 'u2b';
  static const _bassInstance = 'bass@b';
  static const _sweepInstance = 'lowpass@lp';

  /// プレイヤーごとの今の値（グラフを作り直すときに引き継ぐ）
  static final _states = <int, _FilterState>{};

  static _FilterState _stateOf(Player player) =>
      _states.putIfAbsent(player.hashCode, () => _FilterState());

  /// 曲を開くときに呼ぶ。低音 0dB・ローパス全開・エコー無しの列を付ける
  /// （前の曲の残りも消える）。付いていて値も初期なら何もしない
  static Future<void> install(Player player) async {
    final s = _stateOf(player);
    if (s.installed && s.bassDb == 0 && s.sweepHz == sweepOpenHz && s.echoMs == null) {
      return;
    }
    s
      ..bassDb = 0
      ..sweepHz = sweepOpenHz
      ..echoMs = null;
    await _rebuild(player, s);
  }

  /// 低音シェルフのゲイン（dB、0 = そのまま、[bassCutDb] = 切る）
  static Future<void> setBassDb(Player player, double db) async {
    final s = _stateOf(player);
    if (!s.installed) await _rebuild(player, s);
    if ((s.bassDb - db).abs() < 0.05) return;
    s.bassDb = db;
    await _command(player, 'gain', db.toStringAsFixed(1), _bassInstance);
  }

  /// スイープのカットオフ（Hz）
  static Future<void> setSweep(Player player, double hz) async {
    final s = _stateOf(player);
    if (!s.installed) await _rebuild(player, s);
    if ((s.sweepHz - hz).abs() < 1) return;
    s.sweepHz = hz;
    await _command(player, 'frequency', hz.round().toString(), _sweepInstance);
  }

  /// エコーアウト: [delayMs] 間隔の多段エコーで尾を引かせる（グラフを作り直す。1 回だけ呼ぶ）。
  /// 遅延は拍に同期させる（BPM から 1 拍 / 半拍）
  static Future<void> setEcho(Player player, int? delayMs) async {
    final s = _stateOf(player);
    if (s.installed && s.echoMs == delayMs) return;
    s.echoMs = delayMs;
    await _rebuild(player, s);
  }

  /// すべて初期値に戻す（低音 0dB・全開・エコー無し）。
  /// エコーが付いていればグラフを作り直す。付いていなければ値だけ戻す
  static Future<void> reset(Player player) async {
    final s = _stateOf(player);
    if (!s.installed) return;
    if (s.echoMs != null) {
      s
        ..bassDb = 0
        ..sweepHz = sweepOpenHz
        ..echoMs = null;
      await _rebuild(player, s);
      return;
    }
    await setBassDb(player, 0);
    await setSweep(player, sweepOpenHz);
  }

  /// 旧 API との互換（prepare / 後始末から）。[reset] と同じ
  static Future<void> clear(Player player) => reset(player);

  static Future<void> _rebuild(Player player, _FilterState s) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final parts = <String>[
      '$_bassInstance=f=$bassHz:g=${s.bassDb.toStringAsFixed(1)}',
      '$_sweepInstance=f=${s.sweepHz.round()}',
      if (s.echoMs != null) _echoFilter(s.echoMs!),
    ];
    try {
      await platform.setProperty('af', '@$_chainLabel:lavfi=[${parts.join(',')}]');
      s.installed = true;
    } catch (e) {
      debugPrint('[AudioFilters] フィルタの設定に失敗: $e');
    }
  }

  /// 多段エコー。[delayMs] 間隔で 4 回、半分ずつ減衰
  static String _echoFilter(int delayMs) {
    final d = delayMs.clamp(50, 2000);
    return 'aecho=0.8:0.9:$d|${d * 2}|${d * 3}|${d * 4}:0.5|0.25|0.12|0.06';
  }

  static Future<void> _command(
      Player player, String command, String argument, String target) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.command(['af-command', _chainLabel, command, argument, target]);
    } catch (e) {
      debugPrint('[AudioFilters] $target $command の更新に失敗: $e');
    }
  }

  /// スイープの進み（0 = 開いている、1 = 閉じ切った）→ カットオフ。耳に合わせて対数で動かす
  static double sweepHz(double progress) {
    final p = progress.clamp(0.0, 1.0);
    return exp(log(sweepOpenHz) + (log(sweepClosedHz) - log(sweepOpenHz)) * p);
  }

  /// ベーススワップのランプ（0 = 低音あり、1 = 切った）→ シェルフのゲイン（dB）
  static double bassDb(double progress) => bassCutDb * progress.clamp(0.0, 1.0);
}

class _FilterState {
  bool installed = false;
  double bassDb = 0;
  double sweepHz = AudioFilters.sweepOpenHz;
  int? echoMs;
}
