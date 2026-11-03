import 'dart:math';
import 'dart:typed_data';

import 'fft.dart';

/// 定 Q 変換（CQT）で求めるクロマ（12 音の強さ）。キーの推定に使う（純Dart・副作用なし）。
///
/// 1 オクターブを 36 段（1 半音を 3 つ）に分け、各段をその音の周期に合わせた長さの窓で測る
/// （低い音は長い窓、高い音は短い窓。どの音域でも半音の細かさが同じ）。
/// 以前のふつうの FFT では低い音ほど目が粗く、曲を半音ずらしてもキーが正しくずれたのは
/// 27 回中 10 回だった。この方式は 24 回（librosa の chroma_cqt は 26 回、2026-11 の手元 9 曲）。
///
/// 計算は Brown–Puckette 法: 8192 点の FFT を 1 回してから、各段の周波数特性（前もって求めた
/// 疎なカーネル）を掛ける。窓はこの長さで打ち切る（69Hz より下の段は少し粗くなるが精度は同じだった）。
/// 4 分の曲で PC 0.5 秒ほど
class CqChroma {
  CqChroma._();

  static const _fftSize = 8192;
  static const binsPerOctave = 36;
  static const _octaves = 7;

  /// 一番下の段の音（MIDI 24 = C1、32.7Hz）
  static const _lowestMidi = 24;

  /// フレームの間隔（サンプル、11025Hz で約 0.09 秒）。高い音の段は窓が短い（4kHz で 135 サンプル）ので、
  /// 間隔が広いと曲のごく一部しか聞かない（8192 で 27 回中 19 回、2048 で 23 回、1024 で 26 回）
  static const hop = 1024;

  static final _kernels = <int, _Kernels>{};

  /// フレームごとのクロマ（C 起点 12 要素、各フレームの最大が 1）。
  /// 1 フレーム = [hop] サンプル。無音のフレームは 0 のまま
  static List<Float64List> frames(Int16List pcm, int sampleRate) {
    if (pcm.length < _fftSize) return const [];
    final k = _kernels.putIfAbsent(sampleRate, () => _Kernels(sampleRate));
    final fft = Fft(_fftSize);
    final re = Float64List(_fftSize), im = Float64List(_fftSize);
    final out = <Float64List>[];
    for (var base = 0; base + _fftSize <= pcm.length; base += hop) {
      for (var i = 0; i < _fftSize; i++) {
        re[i] = pcm[base + i] / 32768.0;
        im[i] = 0;
      }
      fft.transform(re, im);
      final chroma = Float64List(12);
      for (var b = 0; b < k.count; b++) {
        final idx = k.index[b], kr = k.re[b], ki = k.im[b];
        var sr = 0.0, si = 0.0;
        for (var j = 0; j < idx.length; j++) {
          final x = idx[j];
          // (re + i im) × (kr + i ki)
          sr += re[x] * kr[j] - im[x] * ki[j];
          si += re[x] * ki[j] + im[x] * kr[j];
        }
        chroma[k.pitchClass[b]] += sqrt(sr * sr + si * si);
      }
      var mx = 0.0;
      for (final v in chroma) {
        if (v > mx) mx = v;
      }
      if (mx > 1e-9) {
        for (var i = 0; i < 12; i++) {
          chroma[i] /= mx;
        }
      }
      out.add(chroma);
    }
    return out;
  }

  /// [frames] の [from]〜[to] を足したもの
  static Float64List sum(List<Float64List> frames, [int from = 0, int? to]) {
    final s = Float64List(12);
    final end = min(to ?? frames.length, frames.length);
    for (var f = max(0, from); f < end; f++) {
      for (var i = 0; i < 12; i++) {
        s[i] += frames[f][i];
      }
    }
    return s;
  }
}

/// 各段の疎な周波数カーネル（共役を取って 1/L 倍したもの。X[k] と掛けて足せば段の値）
class _Kernels {
  _Kernels(int sampleRate) {
    const n = CqChroma._fftSize;
    final q = 1 / (pow(2, 1 / CqChroma.binsPerOctave) - 1);
    final fft = Fft(n);
    final re = Float64List(n), im = Float64List(n);
    const total = CqChroma.binsPerOctave * CqChroma._octaves;
    for (var b = 0; b < total; b++) {
      final midi = CqChroma._lowestMidi + b * 12 / CqChroma.binsPerOctave;
      final f = 440 * pow(2, (midi - 69) / 12);
      if (f >= sampleRate / 2) break;
      final len = min(n, (q * sampleRate / f).round());
      final off = (n - len) ~/ 2;
      re.fillRange(0, n, 0);
      im.fillRange(0, n, 0);
      for (var t = 0; t < len; t++) {
        final w = 0.5 - 0.5 * cos(2 * pi * t / max(1, len - 1));
        final ph = 2 * pi * f * t / sampleRate;
        // conj(kernel) = w · e^{+iωt} / len
        re[off + t] = w * cos(ph) / len;
        im[off + t] = w * sin(ph) / len;
      }
      fft.transform(re, im);
      // 段の値 = Σ x[t]·kernel[t] = (1/L) Σ X[k]·conj(FFT(conj(kernel)))[k]
      var peak = 0.0;
      for (var k = 0; k < n; k++) {
        final m = re[k] * re[k] + im[k] * im[k];
        if (m > peak) peak = m;
      }
      final keep = <int>[];
      for (var k = 0; k < n; k++) {
        if (re[k] * re[k] + im[k] * im[k] > peak * 1e-6) keep.add(k);
      }
      index.add(Int32List.fromList(keep));
      this.re.add(Float64List.fromList([for (final k in keep) re[k] / n]));
      this.im.add(Float64List.fromList([for (final k in keep) -im[k] / n]));
      pitchClass.add(midi.round() % 12);
    }
  }

  final index = <Int32List>[];
  final re = <Float64List>[];
  final im = <Float64List>[];
  final pitchClass = <int>[];
  int get count => index.length;
}
