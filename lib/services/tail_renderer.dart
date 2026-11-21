import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/audio/sfx_library.dart';
import '../core/audio/tail_dsp.dart';
import '../core/audio/transition_effect.dart';
import '../core/native_channels.dart';
import '../models/loop_item.dart';
import 'waveform_service.dart';

/// 切り出しと加工の注文: 前の曲 [item] の切替点 [cutMs]（媒体ミリ秒）の手前から
/// [effect] の音を作る。[beatMediaMs] は前の曲の 1 拍（媒体）、[outRate] は前の曲の再生速度
class TailRequest {
  const TailRequest({
    required this.effect,
    required this.item,
    required this.cutMs,
    required this.beatMediaMs,
    required this.outRate,
  });

  final TransitionEffect effect;
  final LoopItem item;
  final double cutMs;
  final double beatMediaMs;
  final double outRate;

  /// 作り直すかを決める鍵（切替点・演出・テンポ・速度が同じなら同じ音）
  String get key => '${item.id}|${effect.name}|${cutMs.round()}|'
      '${beatMediaMs.round()}|${outRate.toStringAsFixed(3)}';
}

/// 前の曲の切替点の手前を端末でデコードし、エコー・残響・逆回転の音を作る（[TailDsp]）。
///
/// 作った音は一時フォルダの WAV にして、効果音用のプレイヤーで鳴らす（[SfxClip.rendered]）。
/// 覚えておくのは直近の 1 組だけ（[ready]）。切替点・演出・テンポが変わったら作り直す。
/// 通信はしない（端末にある音声だけ: 端末の曲・高音質の音声・自動キャッシュ・オフライン保存）。
/// 作れなければ null（エコー・残響は尾なしのカット、スピンバックは素材の音になる）
class TailRenderer {
  TailRenderer._();

  /// エコーに入れる長さ（拍）。最後の 1 拍を繰り返す
  static const echoInputBeats = 1.0;

  /// 残響に入れる長さ（1 拍。短すぎ・長すぎる曲はこの範囲に収める）
  static const reverbInputMinMs = 400.0;
  static const reverbInputMaxMs = 1500.0;

  /// スピンバックの長さ（2 拍。実時間でこの範囲に収める）
  static const spinBeats = 2;
  static const spinMinMs = 700;
  static const spinMaxMs = 1600;

  /// スピンバックの始まりより後ろに読む長さ（最初は前へ進むので）
  static const spinForwardMs = 150.0;

  /// ネイティブのデコードを待つ上限
  static const decodeTimeout = Duration(seconds: 6);

  static String? _readyKey;
  static SfxClip? _readyClip;
  static String? _jobKey;
  static Future<SfxClip?>? _job;

  /// 作れなかった鍵と時刻（同じものを続けて試さない。音声が後から届くこともあるので、
  /// [retryAfter] 経てば試し直す）
  static String? _failedKey;
  static DateTime? _failedAt;
  static const retryAfter = Duration(seconds: 15);

  /// 作り終えていれば返す
  static SfxClip? ready(String key) => _readyKey == key ? _readyClip : null;

  /// [key] を作っている最中か
  static bool pending(String key) => _jobKey == key && _job != null;

  /// [request] の音を作る。作り終えていればそれ、作っている最中なら同じ仕事を待つ。
  /// 前に作れなかった鍵はもう試さない（null）
  static Future<SfxClip?> ensure(TailRequest request) {
    final key = request.key;
    final done = ready(key);
    if (done != null) return Future.value(done);
    final running = _job;
    if (_jobKey == key && running != null) return running;
    final failedAt = _failedAt;
    if (_failedKey == key &&
        failedAt != null &&
        DateTime.now().difference(failedAt) < retryAfter) {
      return Future.value(null);
    }
    final job = _render(request).catchError((Object e) {
      debugPrint('[DjFx] 曲の音から作れない: $e');
      return null;
    }).then((clip) {
      if (_jobKey == key) {
        _jobKey = null;
        _job = null;
      }
      if (clip != null) {
        _readyKey = key;
        _readyClip = clip;
      } else {
        _failedKey = key;
        _failedAt = DateTime.now();
      }
      return clip;
    });
    _jobKey = key;
    _job = job;
    return job;
  }

  /// スピンバックの長さ（実時間 ms）
  static int spinDurationMs(double beatRealMs) =>
      (beatRealMs * spinBeats).round().clamp(spinMinMs, spinMaxMs);

  /// 残響に入れる長さ（媒体 ms）
  static double reverbInputMs(double beatMediaMs) =>
      beatMediaMs.clamp(reverbInputMinMs, reverbInputMaxMs);

  /// 通信せずに読める [item] の音声（無ければ null）
  static Future<String?> sourceFor(LoopItem item) async {
    if (item.isLocal) {
      return await File(item.uri).exists() ? item.uri : null;
    }
    final id = item.videoId;
    if (id == null) return null;
    return WaveformService.localAudioFor(id, playingUri: item.cachedVideoPath);
  }

  static Future<SfxClip?> _render(TailRequest r) async {
    final kind = switch (r.effect) {
      TransitionEffect.echoTail => TailKind.echo,
      TransitionEffect.reverbTail => TailKind.reverb,
      TransitionEffect.spinback => TailKind.backspin,
      _ => null,
    };
    if (kind == null || r.beatMediaMs <= 0) return null;
    final source = await sourceFor(r.item);
    if (source == null) {
      debugPrint('[DjFx] 曲の音が端末に無いので作らない（${r.item.title}）');
      return null;
    }
    final rate = r.outRate > 0 ? r.outRate : 1.0;
    final beatRealMs = r.beatMediaMs / rate;
    var spinMs = 0;
    var spinStartMs = 0.0;
    final (double fromMs, double toMs) = switch (kind) {
      TailKind.echo => (r.cutMs - r.beatMediaMs * echoInputBeats, r.cutMs),
      TailKind.reverb => (r.cutMs - reverbInputMs(r.beatMediaMs), r.cutMs),
      TailKind.backspin => () {
          spinMs = spinDurationMs(beatRealMs);
          // 巻き戻し始める位置（そこから切替点までが実時間で spinMs）
          spinStartMs = r.cutMs - spinMs * rate;
          return (
            spinStartMs - TailDsp.spinRewindMs(spinMs),
            spinStartMs + spinForwardMs,
          );
        }(),
    };
    final from = max(0.0, fromMs);
    if (toMs <= from) return null;
    final raw = await NativeChannels.waveform.invokeMethod<dynamic>('decodeSegment', {
      'url': source,
      'startMs': from.round(),
      'endMs': toMs.round(),
    }).timeout(decodeTimeout);
    if (raw is! Map) return null;
    final bytes = raw['pcm'];
    final sampleRate = raw['sampleRate'];
    final channels = raw['channels'];
    if (bytes is! Uint8List || bytes.isEmpty || sampleRate is! int || channels is! int) {
      return null;
    }
    final job = TailJob(
      kind: kind,
      pcm: _toInt16(bytes),
      channels: channels,
      sampleRate: sampleRate,
      beatMs: beatRealMs,
      startFrame: ((spinStartMs - from) * sampleRate / 1000).round(),
      durationMs: spinMs,
    );
    final result = await compute(TailDsp.render, job);
    if (result.durationMs <= 0) return null;
    final path = await _write(result.wav);
    debugPrint('[DjFx] 曲の音から作った: ${r.effect.name} ${result.durationMs}ms '
        '（${from.round()}〜${toMs.round()}ms を ${sampleRate}Hz × $channels）');
    return SfxClip.rendered(
      kind == TailKind.backspin ? SfxRole.spinback : SfxRole.tail,
      path,
      result.durationMs,
    );
  }

  /// 一時フォルダに書く。前に作ったものは消す（鳴っている最中でも、開いているファイルは
  /// 消しても最後まで読める）
  static Future<String> _write(Uint8List wav) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/dj_render');
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } else {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/tail_${DateTime.now().microsecondsSinceEpoch}.wav');
    await file.writeAsBytes(wav, flush: true);
    return file.path;
  }

  /// ネイティブはリトルエンディアンの 16bit で返す。奇数オフセットだと view できないのでコピーする
  static Int16List _toInt16(Uint8List bytes) {
    if (bytes.offsetInBytes.isEven) {
      return Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
    }
    return Int16List.view(Uint8List.fromList(bytes).buffer);
  }
}
