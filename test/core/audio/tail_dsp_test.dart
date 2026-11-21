import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/tail_dsp.dart';

/// 前の曲そのものの音から作る、切り替わりの音（エコー・残響・逆回転）
void main() {
  const sr = 44100;
  // 120 BPM: 1 拍 500ms
  const beatMs = 500.0;
  const beatFrames = sr * beatMs ~/ 1000;

  /// 同じ乱数のノイズ（モノラル）
  Float32List noise(int frames, {int seed = 1, double amp = 0.5}) {
    final r = Random(seed);
    return Float32List.fromList(
        [for (var i = 0; i < frames; i++) (r.nextDouble() * 2 - 1) * amp]);
  }

  double rms(Float32List x, int from, int to) {
    var s = 0.0;
    for (var i = from; i < to; i++) {
      s += x[i] * x[i];
    }
    return sqrt(s / max(1, to - from));
  }

  int argMaxAbs(Float32List x, int from, int to) {
    var best = from;
    for (var i = from; i < to; i++) {
      if (x[i].abs() > x[best].abs()) best = i;
    }
    return best;
  }

  group('エコーアウト', () {
    test('半拍ごとに繰り返し、回を追って小さくなる。長さは繰り返しの数 × 半拍', () {
      final out = TailDsp.echo(noise(beatFrames),
          channels: 1, sampleRate: sr, beatMs: beatMs);
      const delay = beatFrames ~/ 2;
      expect(out.length % delay, 0);
      final repeats = out.length ~/ delay;
      expect(repeats, greaterThanOrEqualTo(6));
      expect(repeats, lessThanOrEqualTo(TailDsp.echoMaxRepeats));
      var prev = double.infinity;
      for (var k = 1; k < repeats; k++) {
        final r = rms(out, k * delay, (k + 1) * delay);
        expect(r, lessThan(prev), reason: '$k 個目の半拍');
        prev = r;
      }
      expect(rms(out, 0, delay), greaterThan(0.05), reason: '切替点からすぐ鳴る');
    });

    test('繰り返しは拍に乗る: 最後の拍の中の一音が半拍ずつずれて出てくる', () {
      // 最後の拍の頭から 1000 フレーム目に一音（端のフェードにかからない所）
      const at = 1000;
      final input = Float32List(beatFrames)..[at] = 0.9;
      final out = TailDsp.echo(input, channels: 1, sampleRate: sr, beatMs: beatMs);
      const delay = beatFrames ~/ 2;
      // n 回目は入力全体を n × 半拍遅らせたもの。1 拍 = 2 × 半拍なので
      // n = 2 が切替点から at、n = 3 が at + 半拍
      for (var k = 0; k < 3; k++) {
        final peak = argMaxAbs(out, k * delay, (k + 1) * delay);
        expect(peak, closeTo(k * delay + at, 3), reason: '$k');
      }
    });

    test('ステレオもそのまま、割れない大きさに収める', () {
      final mono = noise(beatFrames * 2, amp: 1);
      final out = TailDsp.echo(mono, channels: 2, sampleRate: sr, beatMs: beatMs);
      expect(out.length.isEven, isTrue);
      for (final v in out) {
        expect(v.abs(), lessThanOrEqualTo(TailDsp.peakLimit + 1e-6));
      }
    });
  });

  group('残響で消す', () {
    test('切替点の直前と同じくらいの大きさで始まり、だんだん消えて最後は無音', () {
      final input = noise(beatFrames);
      final out = TailDsp.reverb(input, channels: 1, sampleRate: sr);
      expect(out.length, TailDsp.reverbTailMs * sr ~/ 1000);
      final match = TailDsp.reverbMatchMs * sr ~/ 1000;
      final hp = TailDsp.highpass(input, 1, sr, TailDsp.tailHighpassHz);
      final ratio = rms(out, 0, match) / rms(hp, beatFrames - match, beatFrames);
      expect(ratio, closeTo(TailDsp.reverbLevel, 0.05));
      expect(rms(out, sr, 2 * sr), lessThan(rms(out, 0, sr)));
      expect(rms(out, out.length - 200, out.length), lessThan(0.002));
    });

    test('ステレオは左右で少し違う広がりになる', () {
      final input = Float32List(beatFrames * 2);
      final n = noise(beatFrames);
      for (var i = 0; i < beatFrames; i++) {
        input[2 * i] = n[i];
        input[2 * i + 1] = n[i];
      }
      final out = TailDsp.reverb(input, channels: 2, sampleRate: sr);
      var diff = 0.0;
      for (var i = 0; i < 2000; i++) {
        diff += (out[2 * i] - out[2 * i + 1]).abs();
      }
      expect(diff, greaterThan(0));
    });
  });

  group('スピンバック', () {
    test('速度: 前向きから一気に逆回転し、だんだん止まる', () {
      const total = 44100;
      const attack = TailDsp.spinAttackMs * sr / 1000;
      expect(TailDsp.spinSpeed(0, attack: attack, totalFrames: total), 1);
      expect(TailDsp.spinSpeed(attack.ceil(), attack: attack, totalFrames: total),
          closeTo(-TailDsp.spinMaxSpeed, 0.01));
      expect(TailDsp.spinSpeed(total - 1, attack: attack, totalFrames: total).abs(),
          lessThan(0.01));
    });

    test('曲の止めた位置から巻き戻す（読む位置が始まりより前へ戻る）。長さは指定どおり', () {
      // 値 = 位置（0〜1）の入力。出力の値が「どこを読んだか」になる
      const frames = sr * 3;
      final input = Float32List.fromList([for (var i = 0; i < frames; i++) i / frames]);
      const start = sr * 2;
      const durationMs = 1000;
      final out = TailDsp.backspin(input,
          channels: 1, sampleRate: sr, startFrame: start, durationMs: durationMs);
      expect(out.length, sr * durationMs ~/ 1000);
      // 始まりは止めた位置
      expect(out[0], closeTo(start / frames, 1e-4));
      // 終わり近く（フェードの前）は止めた位置より 1 秒以上前を読んでいる
      final lateIndex = (out.length * (1 - TailDsp.spinFadeRatio)).floor() - 1;
      expect(out[lateIndex], lessThan((start - sr) / frames));
      // 巻き戻しに要る長さの見積もりに収まる
      final rewound = start - out[lateIndex] * frames;
      expect(rewound, lessThan(TailDsp.spinRewindMs(durationMs) * sr / 1000));
      // 最後は絞って無音へ
      expect(out.last.abs(), lessThan(0.01));
    });
  });

  test('WAV: 16bit PCM のヘッダと中身', () {
    final pcm = Float32List.fromList([0, 0.5, -0.5, 1]);
    final wav = TailDsp.wav(pcm, channels: 2, sampleRate: 48000);
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(b.getUint16(22, Endian.little), 2);
    expect(b.getUint32(24, Endian.little), 48000);
    expect(b.getUint16(34, Endian.little), 16);
    expect(b.getUint32(40, Endian.little), 8);
    expect(wav.length, 44 + 8);
    expect(b.getInt16(46, Endian.little), (0.5 * 32767).round());
    expect(b.getInt16(50, Endian.little), 32767);
  });

  test('render: 16bit の切り出しから作り、長さを返す（3 チャンネル以上は前の 2 つ）', () {
    final r = Random(3);
    final pcm = Int16List.fromList(
        [for (var i = 0; i < beatFrames * 3; i++) r.nextInt(20000) - 10000]);
    final result = TailDsp.render(TailJob(
      kind: TailKind.echo,
      pcm: pcm,
      channels: 3,
      sampleRate: sr,
      beatMs: beatMs,
    ));
    final b = ByteData.sublistView(result.wav);
    expect(b.getUint16(22, Endian.little), 2);
    final frames = (result.wav.length - 44) ~/ 4;
    expect(result.durationMs, (frames * 1000 / sr).round());
    expect(result.durationMs, greaterThan(beatMs * 2));
  });
}
