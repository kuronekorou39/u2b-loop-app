import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/bpm_key_detector.dart';
import 'package:u2b_loop_app/core/audio/musical_key.dart';

const _sr = BpmKeyDetector.analysisSampleRate;

/// 指定BPMのクリック音（短いノイズバースト）
Int16List _click(double bpm, {int seconds = 30}) {
  final y = Int16List(_sr * seconds);
  final period = (_sr * 60 / bpm).round();
  final rng = Random(0);
  for (var i = 0; i + 300 < y.length; i += period) {
    for (var j = 0; j < 300; j++) {
      y[i + j] = ((rng.nextDouble() * 2 - 1) * (1 - j / 300) * 20000).round();
    }
  }
  return y;
}

/// I-IV-V-I の分散和音（C4 基準）
Int16List _chords(int tonic, bool minor, {int seconds = 20}) {
  final third = minor ? 3 : 4;
  final degrees = [
    [0, third, 7],
    [5, 9, 12],
    [7, 11, 14],
    [0, third, 7],
  ];
  final segLen = _sr * seconds ~/ 4;
  final y = Int16List(segLen * 4);
  for (var c = 0; c < 4; c++) {
    for (var i = 0; i < segLen; i++) {
      final t = i / _sr;
      var v = 0.0;
      for (final d in degrees[c]) {
        final f = 261.63 * pow(2, (tonic + d) / 12);
        v += sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t);
      }
      y[c * segLen + i] = (v * 0.2 * 32767).round();
    }
  }
  return y;
}

/// 120 BPM のクリックに、[downbeat] 拍目から 4 拍ごとに変わる和音を重ねたもの（60 秒）
Int16List _bars(int downbeat) {
  const seconds = 60, bpm = 120.0;
  final y = Int16List(_sr * seconds);
  final beatLen = _sr * 60 / bpm;
  const progression = [
    [0, 4, 7],
    [5, 9, 12],
    [7, 11, 14],
    [9, 12, 16],
  ];
  final click = _click(bpm, seconds: seconds);
  for (var i = 0; i < y.length; i++) {
    final beat = (i / beatLen).floor();
    final bar = ((beat - downbeat) / 4).floor();
    final chord = progression[bar % 4];
    final t = i / _sr;
    var v = 0.0;
    for (final d in chord) {
      v += sin(2 * pi * 261.63 * pow(2, d / 12) * t);
    }
    y[i] = (v * 0.12 * 32767 + click[i] * 0.5).round().clamp(-32768, 32767);
  }
  return y;
}

void main() {
  group('BPM検出', () {
    for (final bpm in [72.0, 97.0, 128.0]) {
      test('クリック $bpm BPM を ±2% で当てる', () {
        final result = BpmKeyDetector.detectBpm(_click(bpm), _sr);
        expect(result, isNotEmpty);
        expect(result.first.bpm, closeTo(bpm, bpm * 0.02));
      });
    }

    test('174 BPM は倍/半分の候補も含めて当てる（速いテンポは曖昧）', () {
      final result = BpmKeyDetector.detectBpm(_click(174), _sr);
      final hit = result.any((c) =>
          (c.bpm - 174).abs() < 174 * 0.02 || (c.bpm - 87).abs() < 87 * 0.02);
      expect(hit, isTrue, reason: '$result');
    });

    test('無音は候補なし', () {
      expect(BpmKeyDetector.detectBpm(Int16List(_sr * 10), _sr), isEmpty);
    });

    test('短すぎる入力は候補なし', () {
      expect(BpmKeyDetector.detectBpm(Int16List(100), _sr), isEmpty);
    });
  });

  group('小節頭の検出', () {
    for (final downbeat in [0, 1, 3]) {
      test('和音が $downbeat 拍目から 4 拍ごとに変わる曲で 1 拍目を当てる', () {
        final pcm = _bars(downbeat);
        final env = BpmKeyDetector.onsetEnvelope(pcm, _sr)!;
        final grid = BpmKeyDetector.detectBeatGrid(env, 120)!;
        final result = BpmKeyDetector.detectDownbeat(pcm, _sr, grid)!;
        // クリックは 0ms から（格子の最初の拍は 0ms とは限らないので曲頭から数える）
        final beat = (result.ms / grid.periodMs).round();
        expect(beat % 4, downbeat);
        expect(result.confidence, greaterThanOrEqualTo(0.9));
      });
    }

    test('8 小節に満たない曲は推定しない', () {
      final pcm = _click(120, seconds: 10);
      final env = BpmKeyDetector.onsetEnvelope(pcm, _sr)!;
      final grid = BpmKeyDetector.detectBeatGrid(env, 120)!;
      expect(BpmKeyDetector.detectDownbeat(pcm, _sr, grid), isNull);
    });
  });

  group('キー検出', () {
    for (final (tonic, minor, expected) in [
      (0, false, 'Cmaj'),
      (7, false, 'Gmaj'),
      (9, true, 'Amin'),
      (2, true, 'Dmin'),
    ]) {
      test('$expected の和音進行を当てる', () {
        final result = BpmKeyDetector.detectKey(_chords(tonic, minor), _sr);
        expect(result.first.key, expected, reason: '$result');
      });
    }

    test('無音は候補なし', () {
      expect(BpmKeyDetector.detectKey(Int16List(_sr * 10), _sr), isEmpty);
    });
  });

  group('MusicalKey', () {
    test('Camelot 表記', () {
      expect(MusicalKey.camelot('Cmaj'), '8B');
      expect(MusicalKey.camelot('Amin'), '8A');
      expect(MusicalKey.camelot('Gmaj'), '9B');
      expect(MusicalKey.camelot('A#maj'), '6B');
      expect(MusicalKey.camelot('Gmin'), '6A');
      expect(MusicalKey.camelot('Bmaj'), '1B');
      expect(MusicalKey.camelot('Emaj'), '12B');
      expect(MusicalKey.camelot(null), isNull);
      expect(MusicalKey.camelot('Hmaj'), isNull);
    });

    test('相性: 同一・平行調・隣接は true、それ以外は false', () {
      expect(MusicalKey.isCompatible('Gmin', 'Gmin'), isTrue);
      expect(MusicalKey.isCompatible('Gmin', 'A#maj'), isTrue);
      expect(MusicalKey.isCompatible('Emaj', 'Bmaj'), isTrue); // 12B-1B
      expect(MusicalKey.isCompatible('Emaj', 'Amaj'), isTrue); // 12B-11B
      expect(MusicalKey.isCompatible('Cmaj', 'F#maj'), isFalse);
      expect(MusicalKey.isCompatible('Cmaj', 'Gmin'), isFalse); // 8B-6A
      expect(MusicalKey.isCompatible('Cmaj', null), isFalse);
    });

    test('parse と name は往復する', () {
      for (final k in MusicalKey.allKeys) {
        final (tonic, mode) = MusicalKey.parse(k)!;
        expect(MusicalKey.name(tonic, mode), k);
      }
    });
  });
}
