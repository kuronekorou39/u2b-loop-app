import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/audio/sfx_library.dart';

/// 切り替えの効果音を鳴らす（曲の 2 枚とは別の、音声専用の 3 枚目のプレイヤー）。
///
/// 鳴らす順に並べたクリップを先に開いておき（`open(play: false)`）、合図で `play()` する。
/// ライザー → インパクトのように続けて鳴らすものは mpv のプレイリストに並べ、
/// `gapless-audio=yes` で切れ目なく続ける（同じ形式の WAV 同士なら途切れない）。
///
/// `play()` を呼んでから音が出るまでの遅れは機種で違うので、位置が動き出すまでの時間を測って
/// 次から前倒しする（[startLatencyMs]）。
///
/// ライザーは小節数に合わせて速度を変えて鳴らす（[start] の rate）。速度はプレイヤー全体に
/// かかるので、続けて鳴るインパクトの前に [setRate] で 1 に戻す
class TransitionSfx {
  TransitionSfx(this._player);

  final Player _player;

  /// `play()` から音が出るまでの遅れの見込み（実測の平滑値）。初回は仮の値
  static double startLatencyMs = 120;

  /// 遅延の実測を諦めるまで
  static const _latencyMeasureTimeout = Duration(seconds: 2);

  List<SfxClip> _loaded = const [];
  bool _ready = false;
  bool _configured = false;
  Future<void>? _loading;
  StreamSubscription<Duration>? _latencySub;
  Timer? _latencyTimeout;

  /// 開いてあるクリップ（鳴らす順）
  List<SfxClip> get loaded => _loaded;

  /// [clips] を鳴らす順に開いて待機する。同じ列が開いてあれば何もしない
  Future<void> load(List<SfxClip> clips) async {
    // 先読み（armCrossfade）の途中で交差が始まったら、開き終わるのを待ってから判断する
    if (_loading != null) await _loading;
    if (clips.isEmpty) {
      await stop();
      return;
    }
    if (_ready && _sameClips(clips)) return;
    final loading = _open(clips);
    _loading = loading;
    try {
      await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  Future<void> _open(List<SfxClip> clips) async {
    _ready = false;
    _loaded = List.unmodifiable(clips);
    try {
      if (!_configured) {
        _configured = true;
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('gapless-audio', 'yes');
        }
      }
      await setRate(1);
      await _player.open(Playlist([for (final c in clips) Media(c.uri)]),
          play: false);
      _ready = true;
    } catch (e) {
      debugPrint('[TransitionSfx] 効果音を開けない: $e');
      _loaded = const [];
    }
  }

  bool _sameClips(List<SfxClip> clips) {
    if (clips.length != _loaded.length) return false;
    for (var i = 0; i < clips.length; i++) {
      if (clips[i].asset != _loaded[i].asset) return false;
    }
    return true;
  }

  /// 鳴らす。[volume] は曲の音量と同じ 0〜100 の尺度（曲より少し下げた値を渡す）。
  /// [rate] は再生速度（ライザーを小節数に合わせる。音程は保たれる）
  Future<void> start({required double volume, double rate = 1}) async {
    if (!_ready) return;
    _ready = false;
    try {
      await _player.setVolume(volume.clamp(0.0, 100.0));
      await setRate(rate);
      final t0 = DateTime.now();
      await _player.play();
      _measureLatency(t0);
    } catch (e) {
      debugPrint('[TransitionSfx] 効果音の再生に失敗: $e');
    }
  }

  double _rate = 1;

  /// 再生速度を変える（同じ値なら何もしない）
  Future<void> setRate(double rate) async {
    if (_rate == rate) return;
    _rate = rate;
    try {
      await _player.setRate(rate);
    } catch (e) {
      debugPrint('[TransitionSfx] 速度の変更に失敗: $e');
    }
  }

  /// 止めて捨てる（取り消し時）。鳴り終わりは mpv に任せる（keep-open で止まる）
  Future<void> stop() async {
    _ready = false;
    _loaded = const [];
    _cancelLatencyMeasure();
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[TransitionSfx] 効果音の停止に失敗: $e');
    }
  }

  void _measureLatency(DateTime t0) {
    _cancelLatencyMeasure();
    _latencySub = _player.stream.position.listen((pos) {
      if (pos <= Duration.zero) return;
      final measured = DateTime.now().difference(t0).inMilliseconds - pos.inMilliseconds;
      if (measured > 0 && measured < 1000) {
        startLatencyMs = 0.5 * startLatencyMs + 0.5 * measured;
        debugPrint('[TransitionSfx] 開始遅延 ${measured}ms → 見込み ${startLatencyMs.round()}ms');
      }
      _cancelLatencyMeasure();
    });
    _latencyTimeout = Timer(_latencyMeasureTimeout, _cancelLatencyMeasure);
  }

  void _cancelLatencyMeasure() {
    _latencySub?.cancel();
    _latencySub = null;
    _latencyTimeout?.cancel();
    _latencyTimeout = null;
  }

  /// 曲の音量 [trackVolume]（0〜100）に対する効果音の音量。[levelDb] は曲との差（0 = 同じ）
  static double volumeFor(double trackVolume, int levelDb) =>
      (trackVolume * _gain(levelDb)).clamp(0.0, 100.0);

  static double _gain(int db) => db >= 0 ? 1 : pow(10, db / 20).toDouble();
}
