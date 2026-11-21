import 'dart:math';
import 'dart:typed_data';

/// 前の曲そのものの音から、切り替わりで鳴らす音を作る（純粋関数）。
///
/// 端末の再生ライブラリはイコライザーしか持たず、エコー・残響・逆再生を曲にかけられない。
/// そこで切替点の手前を端末でデコードし（[TailRenderer]）、ここで加工して WAV にし、
/// 効果音用のプレイヤーで鳴らす。前の曲は切替点で止めるので、作った音が曲の続きに聞こえる。
///
/// - [echo]: エコーアウト。最後の 1 拍を半拍ごとに繰り返し、回を追うごとにこもらせて消す
/// - [reverb]: 残響で消す。最後の音を長い残響（Freeverb 系）にして広げながら消す
/// - [backspin]: スピンバック。最後の音を一気に逆回転させ、だんだん止まる
///
/// PCM はインターリーブの float（−1〜1）、チャンネル数は 1 か 2
class TailDsp {
  TailDsp._();

  // --- 共通 ---

  /// 尾から先に抜く低音（次の曲のキック・ベースと濁らせない。DJ もエコーにはハイパスをかける）
  static const tailHighpassHz = 180.0;

  /// 切り出しの端と作った音の始まり・終わりの短いフェード（プツッという音を消す）
  static const edgeFadeMs = 4.0;

  /// 作った音の大きさの上限（足し合わせで割れないように）
  static const peakLimit = 0.97;

  // --- エコーアウト ---

  /// エコーの間隔（拍）。半拍 = 8 分音符なので、次の曲の拍とずれない
  static const echoDelayBeats = 0.5;

  /// 1 回目の繰り返しの大きさと、回ごとの減り方
  static const echoFirstGain = 0.7;
  static const echoFeedback = 0.55;

  /// 繰り返すたびにかけるローパス（テープエコーのように回を追って暗くなる）
  static const echoLowpassHz = 4500.0;

  /// これより小さい繰り返しは足さない（−40dB）
  static const echoSilentGain = 0.01;

  /// 繰り返しの回数の上限
  static const echoMaxRepeats = 24;

  // --- 残響 ---

  /// 切替点からの残響の長さと、最後に絞る長さ
  static const reverbTailMs = 4000;
  static const reverbFadeMs = 1500;

  /// 櫛形フィルタの戻り（大きいほど長く残る。0.94 で 4 秒ほど）と、高音の減り
  static const reverbFeedback = 0.94;
  static const reverbDamp = 0.2;

  /// 残響の始まりの大きさ（切替点の直前の大きさに対して）
  static const reverbLevel = 0.65;

  /// 大きさを比べる長さ（切替点の直前と、残響の始まり）
  static const reverbMatchMs = 250;

  // --- スピンバック ---

  /// 逆回転の最高速度（通常の何倍で巻き戻すか）
  static const spinMaxSpeed = 3.5;

  /// 前向きから逆回転に変わるまで（手でレコードを引き戻す一瞬）
  static const spinAttackMs = 60.0;

  /// 止まっていく速さの形（大きいほど早く遅くなる）
  static const spinDecayPower = 1.6;

  /// 終わりを絞る割合（遅くなった低い唸りを残さない）
  static const spinFadeRatio = 0.25;

  /// 作れる長さで、巻き戻しに要る切替点より前の長さ（[spinMaxSpeed] で巻き戻す距離 + 余裕）
  static double spinRewindMs(int durationMs) =>
      durationMs * spinMaxSpeed / (1 + spinDecayPower) + 300;

  /// [job] を作る（isolate で呼ぶ入口）
  static TailResult render(TailJob job) {
    final (pcm, channels) = _toFloat(job.pcm, job.channels);
    final sr = job.sampleRate;
    final Float32List out;
    switch (job.kind) {
      case TailKind.echo:
        out = echo(pcm, channels: channels, sampleRate: sr, beatMs: job.beatMs);
      case TailKind.reverb:
        out = reverb(pcm, channels: channels, sampleRate: sr);
      case TailKind.backspin:
        out = backspin(pcm,
            channels: channels,
            sampleRate: sr,
            startFrame: job.startFrame,
            durationMs: job.durationMs);
    }
    final frames = out.length ~/ channels;
    return TailResult(
      wav(out, channels: channels, sampleRate: sr),
      (frames * 1000 / sr).round(),
    );
  }

  /// エコーアウト。[input] は切替点の直前（最後が切替点）。返すのは切替点から鳴らす音。
  /// n 回目の繰り返しは入力全体を n × 間隔だけ遅らせたもの（切替点より後ろに出る部分だけ）
  static Float32List echo(Float32List input,
      {required int channels, required int sampleRate, required double beatMs}) {
    final frames = input.length ~/ channels;
    if (frames == 0 || beatMs <= 0) return Float32List(0);
    final delay = max(1, (beatMs * echoDelayBeats * sampleRate / 1000).round());
    final gains = <double>[];
    for (var g = echoFirstGain;
        g >= echoSilentGain && gains.length < echoMaxRepeats;
        g *= echoFeedback) {
      gains.add(g);
    }
    final outFrames = gains.length * delay;
    final out = Float32List(outFrames * channels);
    var cur = fadeEdges(highpass(input, channels, sampleRate, tailHighpassHz),
        channels, sampleRate);
    for (var n = 1; n <= gains.length; n++) {
      cur = lowpass(cur, channels, sampleRate, echoLowpassHz);
      final gain = gains[n - 1];
      // 入力の 0 フレーム目が出てくる位置（切替点からのフレーム数。負なら手前は捨てる）
      final offset = n * delay - frames;
      for (var i = max(0, -offset); i < frames; i++) {
        final o = offset + i;
        if (o >= outFrames) break;
        for (var c = 0; c < channels; c++) {
          out[o * channels + c] += cur[i * channels + c] * gain;
        }
      }
    }
    return _finish(out, channels, sampleRate, fadeOutMs: beatMs * echoDelayBeats);
  }

  /// 残響で消す。[input] は切替点の直前。残響を入力の間に溜めてから、
  /// 切替点より後ろ（入力が終わった後）の残響だけを返す
  static Float32List reverb(Float32List input,
      {required int channels, required int sampleRate}) {
    final frames = input.length ~/ channels;
    if (frames == 0) return Float32List(0);
    final hp = highpass(input, channels, sampleRate, tailHighpassHz);
    final tailFrames = reverbTailMs * sampleRate ~/ 1000;
    final left = _Freeverb(sampleRate, spread: 0);
    final right = _Freeverb(sampleRate, spread: _Freeverb.stereoSpread);
    final out = Float32List(tailFrames * channels);
    for (var f = 0; f < frames + tailFrames; f++) {
      var x = 0.0;
      if (f < frames) {
        for (var c = 0; c < channels; c++) {
          x += hp[f * channels + c];
        }
        x /= channels;
      }
      final l = left.process(x);
      final r = right.process(x);
      if (f < frames) continue;
      final o = (f - frames) * channels;
      if (channels == 1) {
        out[o] = (l + r) / 2;
      } else {
        out[o] = l;
        out[o + 1] = r;
      }
    }
    // 大きさを切替点の直前に合わせる（残響の始まりが直前の [reverbLevel] 倍）
    final matchFrames = reverbMatchMs * sampleRate ~/ 1000;
    final inRms = _rms(hp, channels, max(0, frames - matchFrames), frames);
    final tailRms = _rms(out, channels, 0, min(tailFrames, matchFrames));
    if (tailRms > 0 && inRms > 0) {
      final scale = reverbLevel * inRms / tailRms;
      for (var i = 0; i < out.length; i++) {
        out[i] *= scale;
      }
    }
    return _finish(out, channels, sampleRate, fadeOutMs: reverbFadeMs.toDouble());
  }

  /// スピンバック。[input] の [startFrame] から、前向き → 逆回転（最高 [spinMaxSpeed] 倍）→
  /// だんだん止まる、を [durationMs] で。始まりは鳴っていた曲と同じ位置から前へ進むので、
  /// 曲を止めた所につながる
  static Float32List backspin(Float32List input,
      {required int channels,
      required int sampleRate,
      required int startFrame,
      required int durationMs}) {
    final frames = input.length ~/ channels;
    final outFrames = durationMs * sampleRate ~/ 1000;
    if (frames < 2 || outFrames == 0) return Float32List(0);
    final attack = max(1.0, spinAttackMs * sampleRate / 1000);
    final out = Float32List(outFrames * channels);
    var pos = startFrame.clamp(0, frames - 1).toDouble();
    for (var k = 0; k < outFrames; k++) {
      final i0 = pos.floor();
      if (i0 >= 0 && i0 + 1 < frames) {
        final frac = pos - i0;
        for (var c = 0; c < channels; c++) {
          final a = input[i0 * channels + c];
          final b = input[(i0 + 1) * channels + c];
          out[k * channels + c] = a + (b - a) * frac;
        }
      }
      pos += spinSpeed(k, attack: attack, totalFrames: outFrames);
    }
    final fadeFrames = (outFrames * spinFadeRatio).round();
    for (var k = outFrames - fadeFrames; k < outFrames; k++) {
      final g = (outFrames - k) / fadeFrames;
      for (var c = 0; c < channels; c++) {
        out[k * channels + c] *= g;
      }
    }
    return _limit(out);
  }

  /// スピンバックの [k] フレーム目の速度（通常の何倍か。負 = 逆回転）
  static double spinSpeed(int k, {required double attack, required int totalFrames}) {
    if (k < attack) return 1 - (1 + spinMaxSpeed) * (k / attack);
    final rest = max(1.0, totalFrames - attack);
    final x = ((k - attack) / rest).clamp(0.0, 1.0);
    return -spinMaxSpeed * pow(1 - x, spinDecayPower);
  }

  /// 16bit の PCM WAV（インターリーブ）
  static Uint8List wav(Float32List pcm, {required int channels, required int sampleRate}) {
    final samples = pcm.length - pcm.length % channels;
    final dataBytes = samples * 2;
    final b = ByteData(44 + dataBytes);
    void tag(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * channels * 2, Endian.little);
    b.setUint16(32, channels * 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < samples; i++) {
      b.setInt16(44 + i * 2, (pcm[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return b.buffer.asUint8List();
  }

  /// 1 次のローパス（チャンネルごと）
  static Float32List lowpass(Float32List x, int channels, int sampleRate, double hz) {
    final a = 1 - exp(-2 * pi * hz / sampleRate);
    final y = Float32List(x.length);
    for (var c = 0; c < channels; c++) {
      var prev = 0.0;
      for (var i = c; i < x.length; i += channels) {
        prev += a * (x[i] - prev);
        y[i] = prev;
      }
    }
    return y;
  }

  /// 1 次のハイパス（チャンネルごと）
  static Float32List highpass(Float32List x, int channels, int sampleRate, double hz) {
    final a = 1 / (1 + 2 * pi * hz / sampleRate);
    final y = Float32List(x.length);
    for (var c = 0; c < channels; c++) {
      var prevX = 0.0, prevY = 0.0;
      for (var i = c; i < x.length; i += channels) {
        prevY = a * (prevY + x[i] - prevX);
        prevX = x[i];
        y[i] = prevY;
      }
    }
    return y;
  }

  /// 切り出しの両端を [edgeFadeMs] で絞る（コピーを返す）
  static Float32List fadeEdges(Float32List x, int channels, int sampleRate) {
    final y = Float32List.fromList(x);
    final frames = y.length ~/ channels;
    final n = min(frames ~/ 2, (edgeFadeMs * sampleRate / 1000).round());
    for (var k = 0; k < n; k++) {
      final g = k / n;
      for (var c = 0; c < channels; c++) {
        y[k * channels + c] *= g;
        y[(frames - 1 - k) * channels + c] *= g;
      }
    }
    return y;
  }

  /// 始まりの短いフェード・終わりの [fadeOutMs] のフェード・大きさの上限
  static Float32List _finish(Float32List out, int channels, int sampleRate,
      {required double fadeOutMs}) {
    final frames = out.length ~/ channels;
    final inFrames = min(frames, (edgeFadeMs * sampleRate / 1000).round());
    for (var k = 0; k < inFrames; k++) {
      for (var c = 0; c < channels; c++) {
        out[k * channels + c] *= k / inFrames;
      }
    }
    final outFrames = min(frames, (fadeOutMs * sampleRate / 1000).round());
    for (var k = 0; k < outFrames; k++) {
      // なめらかに 0 へ（cos の半周）
      final g = 0.5 * (1 + cos(pi * (k + 1) / outFrames));
      final f = frames - outFrames + k;
      for (var c = 0; c < channels; c++) {
        out[f * channels + c] *= g;
      }
    }
    return _limit(out);
  }

  static Float32List _limit(Float32List out) {
    var peak = 0.0;
    for (final v in out) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    if (peak > peakLimit) {
      final s = peakLimit / peak;
      for (var i = 0; i < out.length; i++) {
        out[i] *= s;
      }
    }
    return out;
  }

  static double _rms(Float32List x, int channels, int fromFrame, int toFrame) {
    if (toFrame <= fromFrame) return 0;
    var sum = 0.0;
    for (var i = fromFrame * channels; i < toFrame * channels; i++) {
      sum += x[i] * x[i];
    }
    return sqrt(sum / ((toFrame - fromFrame) * channels));
  }

  /// 16bit → float。3 チャンネル以上は前の 2 つだけ使う
  static (Float32List, int) _toFloat(Int16List pcm, int channels) {
    final inCh = max(1, channels);
    final outCh = min(inCh, 2);
    final frames = pcm.length ~/ inCh;
    final out = Float32List(frames * outCh);
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < outCh; c++) {
        out[f * outCh + c] = pcm[f * inCh + c] / 32768;
      }
    }
    return (out, outCh);
  }
}

enum TailKind { echo, reverb, backspin }

/// isolate に渡す仕事（送れる値だけ）
class TailJob {
  const TailJob({
    required this.kind,
    required this.pcm,
    required this.channels,
    required this.sampleRate,
    this.beatMs = 0,
    this.startFrame = 0,
    this.durationMs = 0,
  });

  final TailKind kind;

  /// 切り出した音（16bit インターリーブ）
  final Int16List pcm;
  final int channels;
  final int sampleRate;

  /// エコーの 1 拍（実時間 ms）
  final double beatMs;

  /// スピンバックを始める位置（[pcm] の中のフレーム）と長さ
  final int startFrame;
  final int durationMs;
}

class TailResult {
  const TailResult(this.wav, this.durationMs);

  final Uint8List wav;
  final int durationMs;
}

/// Freeverb（Jezar の公開版）と同じ作り: 8 本の櫛形フィルタを並べ、4 本の全域通過を直列に
class _Freeverb {
  _Freeverb(int sampleRate, {required int spread}) {
    final scale = sampleRate / 44100;
    for (final t in _combTuning) {
      _combs.add(_Comb(max(1, ((t + spread) * scale).round())));
    }
    for (final t in _allpassTuning) {
      _allpasses.add(_Allpass(max(1, ((t + spread) * scale).round())));
    }
  }

  static const stereoSpread = 23;
  static const _combTuning = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
  static const _allpassTuning = [556, 441, 341, 225];

  /// 入力を小さくしてから足す（8 本の和が大きくなりすぎない）
  static const _inputGain = 0.015;

  final _combs = <_Comb>[];
  final _allpasses = <_Allpass>[];

  double process(double x) {
    final input = x * _inputGain;
    var out = 0.0;
    for (final c in _combs) {
      out += c.process(input);
    }
    for (final a in _allpasses) {
      out = a.process(out);
    }
    return out;
  }
}

class _Comb {
  _Comb(int size) : _buf = Float64List(size);

  final Float64List _buf;
  int _i = 0;
  double _store = 0;

  double process(double x) {
    final out = _buf[_i];
    _store = out * (1 - TailDsp.reverbDamp) + _store * TailDsp.reverbDamp;
    _buf[_i] = x + _store * TailDsp.reverbFeedback;
    if (++_i >= _buf.length) _i = 0;
    return out;
  }
}

class _Allpass {
  _Allpass(int size) : _buf = Float64List(size);

  static const _feedback = 0.5;

  final Float64List _buf;
  int _i = 0;

  double process(double x) {
    final b = _buf[_i];
    _buf[_i] = x + b * _feedback;
    if (++_i >= _buf.length) _i = 0;
    return b - x;
  }
}
