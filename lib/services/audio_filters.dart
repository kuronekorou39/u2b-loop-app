import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// media_kit（libmpv）の音声フィルタ。
///
/// mpv の `af` プロパティに ffmpeg（lavfi）のフィルタを書き、交差中は `af-command` で
/// 値だけ動かす（グラフを作り直さないので音は途切れない）。
///
/// **使える音声フィルタは `equalizer` だけ。** media_kit の Android ビルド
/// （libmpv-android-video-build、mpv 0.36 系 / FFmpeg 6.0）は ffmpeg を
/// `--disable-filters --enable-filter=overlay --enable-filter=equalizer` で作っていて、
/// bass / lowpass / highpass / aecho は入っていない。そのため
/// - 低音の入れ替え（ベーススワップ）: [bassHz] を中心に幅 [bassWidthHz] のピーキング EQ を
///   0dB → [bassCutDb] まで下げる（低音シェルフの代わり）
/// - スイープ（こもらせる）: 上端 [sweepTopHz] と「縁」の間を [sweepCutDb] 削るピーキング EQ。
///   縁を下げるほど中心を下げ、幅を広げる（ローパスの代わり。縁より下は残る）
/// - エコーは作れないので無い
///
/// **作れないフィルタ列を `af` に入れたまま曲を開くと、その曲の音声トラックが無効になる**
/// （mpv は開くときのフィルタ列の失敗で音声を捨てる。映像があれば無音で進み、音声だけなら止まる。
/// 再生中の変更の失敗なら元の音が鳴り続ける）。v1.95〜v1.97 で 2 曲目から無音になったのはこれ。
/// - 曲を開く前は必ず [detach] で外す（PlaylistEngine.prepare / PlayerLoader の両方）
/// - 付けるのは音声が鳴れる状態（開いてメタデータが取れた後）になってから（[install]）
/// - 外部音声を付け替える間も外す（[suspend] / [resume]）
/// - mpv が「Audio filter initialized failed」を出したら以後いっさい触らない（[noteLog]）
///
/// `af-command <label> <command> <argument>`（mpv 0.36 には宛先を指定する target 引数が無い）
/// なので、低音とスイープは別々の lavfi フィルタにして mpv 側のラベルで宛先を分ける
class AudioFilters {
  AudioFilters._();

  /// 低音を下げるピーキング EQ の中心と幅（Hz）。キックとベースが主に 40〜150Hz
  static const bassHz = 100;
  static const bassWidthHz = 200;

  /// 低音を切ったときのゲイン（dB）
  static const bassCutDb = -18.0;

  /// スイープの縁（Hz）: 開いた所と閉じ切った所。縁と [sweepTopHz] の間を削る
  static const sweepOpenHz = 15000.0;
  static const sweepClosedHz = 250.0;
  static const sweepTopHz = 16000.0;
  static const sweepCutDb = -30.0;

  static const _bassLabel = 'u2b_bass';
  static const _sweepLabel = 'u2b_sweep';

  /// mpv がフィルタ列を作れなかったら false にして、以後は何もしない
  static bool available = true;

  /// プレイヤーごとの今の値（付け直すときに引き継ぐ）
  static final _states = <Player, _FilterState>{};

  static _FilterState _stateOf(Player player) =>
      _states.putIfAbsent(player, () => _FilterState());

  static bool isInstalled(Player player) => _states[player]?.installed ?? false;

  /// 曲を開く前に呼ぶ。`af` を空にして、前の曲の残り（2 枚のプレイヤーを使い回す）も消す
  static Future<void> detach(Player player) async {
    _stateOf(player).reset();
    await _setAf(player, '');
  }

  /// 音声が鳴れる状態になってから呼ぶ。低音 0dB・スイープ全開の列を付ける。付いていれば何もしない
  static Future<void> install(Player player) async {
    if (!available) return;
    final s = _stateOf(player);
    if (s.installed) return;
    await _rebuild(player, s);
  }

  /// 外部音声を付け替える間だけ外す（音声チェーンの作り直しに列を持ち込まない）。
  /// 戻り値は外したか（付いていなければ false）
  static Future<bool> suspend(Player player) async {
    final s = _stateOf(player);
    if (!s.installed) return false;
    s.installed = false;
    await _setAf(player, '');
    return true;
  }

  /// [suspend] の後、覚えている値で付け直す
  static Future<void> resume(Player player) async {
    if (!available) return;
    await _rebuild(player, _stateOf(player));
  }

  /// 停止したプレイヤーの状態だけ忘れる（mpv 側の列は次に開く前の [detach] で消える）
  static void forget(Player player) => _states[player]?.reset();

  /// 低音のゲイン（dB、0 = そのまま、[bassCutDb] = 切る）
  static Future<void> setBassDb(Player player, double db) async {
    if (!available) return;
    final s = _stateOf(player);
    if (!s.installed) await _rebuild(player, s);
    if ((s.bassDb - db).abs() < 0.05) return;
    s.bassDb = db;
    await _command(player, _bassLabel, 'gain', db.toStringAsFixed(1));
  }

  /// スイープの縁（Hz）。ここから上端までを削る
  static Future<void> setSweep(Player player, double edgeHz) async {
    if (!available) return;
    final s = _stateOf(player);
    if (!s.installed) await _rebuild(player, s);
    if ((s.sweepHz - edgeHz).abs() < 1) return;
    s.sweepHz = edgeHz;
    final (f, w) = sweepBand(edgeHz);
    await _command(player, _sweepLabel, 'frequency', f.round().toString());
    await _command(player, _sweepLabel, 'width', w.toStringAsFixed(2));
  }

  /// 値を初期に戻す（低音 0dB・スイープ全開）。付いていなければ何もしない
  static Future<void> reset(Player player) async {
    if (!_stateOf(player).installed) return;
    await setBassDb(player, 0);
    await setSweep(player, sweepOpenHz);
  }

  static Future<void> _rebuild(Player player, _FilterState s) async {
    if (!available) return;
    final (f, w) = sweepBand(s.sweepHz);
    final af = '@$_bassLabel:lavfi=[equalizer=f=$bassHz:t=h:w=$bassWidthHz'
        ':g=${s.bassDb.toStringAsFixed(1)}],'
        '@$_sweepLabel:lavfi=[equalizer=f=${f.round()}:t=o:w=${w.toStringAsFixed(2)}'
        ':g=${sweepCutDb.toStringAsFixed(1)}]';
    if (await _setAf(player, af)) s.installed = true;
  }

  static Future<bool> _setAf(Player player, String value) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return false;
    try {
      await platform.setProperty('af', value);
      return true;
    } catch (e) {
      debugPrint('[AudioFilters] af の設定に失敗: $e');
      return false;
    }
  }

  static Future<void> _command(
      Player player, String label, String command, String argument) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.command(['af-command', label, command, argument]);
    } catch (e) {
      debugPrint('[AudioFilters] $label $command の更新に失敗: $e');
    }
  }

  /// mpv のログ（error 以上）を見て、フィルタ列が作れなかったら以後使うのをやめ、
  /// 付いている列を全部外す（次の曲を無音にしないため）
  static void noteLog(PlayerLog log) {
    if (!available) return;
    if (log.level != 'error' && log.level != 'fatal') return;
    final text = log.text;
    final fromLavfi = log.prefix.startsWith('lavfi') || log.prefix.startsWith('af');
    final hit = text.contains('Audio filter initialized failed') ||
        text.contains('filter chain') ||
        (fromLavfi && (text.contains('graph') || text.contains('filter')));
    if (!hit) return;
    available = false;
    debugPrint('[AudioFilters] この端末ではフィルタ列が作れない（${log.prefix}: $text）。以後は付けない');
    for (final entry in _states.entries) {
      entry.value.reset();
      unawaited(_setAf(entry.key, ''));
    }
  }

  /// スイープの進み（0 = 開いている、1 = 閉じ切った）→ 縁（Hz）。耳に合わせて対数で動かす
  static double sweepHz(double progress) {
    final p = progress.clamp(0.0, 1.0);
    return exp(log(sweepOpenHz) + (log(sweepClosedHz) - log(sweepOpenHz)) * p);
  }

  /// 縁 [edgeHz] から [sweepTopHz] までを削るピーキング EQ の (中心 Hz, 幅 オクターブ)。
  /// 中心は両端の幾何平均、幅は両端の比。開いた所では上端近くの狭い切れ込みで、ほぼ聞こえない
  static (double, double) sweepBand(double edgeHz) {
    final edge = edgeHz.clamp(sweepClosedHz, sweepOpenHz);
    return (sqrt(edge * sweepTopHz), log(sweepTopHz / edge) / ln2);
  }

  /// ベーススワップのランプ（0 = 低音あり、1 = 切った）→ ゲイン（dB）
  static double bassDb(double progress) => bassCutDb * progress.clamp(0.0, 1.0);
}

class _FilterState {
  bool installed = false;
  double bassDb = 0;
  double sweepHz = AudioFilters.sweepOpenHz;

  void reset() {
    installed = false;
    bassDb = 0;
    sweepHz = AudioFilters.sweepOpenHz;
  }
}
