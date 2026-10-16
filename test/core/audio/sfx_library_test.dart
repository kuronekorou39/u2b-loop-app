import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/sfx_library.dart';

void main() {
  group('SfxLibrary.pick', () {
    test('窓に収まる最も長いライザー（少しのはみ出しは許す）', () {
      // 4 拍 @128 BPM = 1875ms → 2 秒
      expect(SfxLibrary.pick(SfxRole.riser, windowMs: 1875).durationMs, 2000);
      // 8 拍 = 3750ms → 4 秒
      expect(SfxLibrary.pick(SfxRole.riser, windowMs: 3750).durationMs, 4000);
      // 16 拍 = 7500ms → 8 秒
      expect(SfxLibrary.pick(SfxRole.riser, windowMs: 7500).durationMs, 8000);
      // 32 拍 → 一番長いもの
      expect(SfxLibrary.pick(SfxRole.riser, windowMs: 15000).durationMs, 8000);
      // 4 拍 @ 90 BPM = 2667ms → 2 秒（4 秒は 1.15 倍を越える）
      expect(SfxLibrary.pick(SfxRole.riser, windowMs: 2667).durationMs, 2000);
    });

    test('どれも収まらなければ最も短いもの', () {
      expect(SfxLibrary.pick(SfxRole.riser, windowMs: 500).durationMs, 2000);
    });

    test('同じ長さの候補は variant で順に回る', () {
      final a = SfxLibrary.pick(SfxRole.riser, windowMs: 2000, variant: 0);
      final b = SfxLibrary.pick(SfxRole.riser, windowMs: 2000, variant: 1);
      final c = SfxLibrary.pick(SfxRole.riser, windowMs: 2000, variant: 3);
      expect(a.asset, isNot(b.asset));
      expect(c.asset, a.asset, reason: '2 秒のライザーは 3 本');
    });

    test('インパクトとスピンバックは 1 本ずつ', () {
      expect(SfxLibrary.pick(SfxRole.impact, windowMs: 100).role, SfxRole.impact);
      expect(SfxLibrary.pick(SfxRole.spinback, windowMs: 100).durationMs, 2736);
    });
  });

  group('同梱ファイル', () {
    test('すべてのクリップが assets/sfx にあり、WAV の長さは宣言どおり', () {
      for (final clip in SfxLibrary.clips) {
        final file = File(clip.asset);
        expect(file.existsSync(), isTrue, reason: '${clip.asset} が無い');
        expect(clip.uri, 'asset:///${clip.asset}');
        if (clip.asset.endsWith('.wav')) {
          final header = file.openSync().readSync(44);
          final bd = ByteData.sublistView(header);
          final channels = bd.getUint16(22, Endian.little);
          final sampleRate = bd.getUint32(24, Endian.little);
          final bits = bd.getUint16(34, Endian.little);
          final dataBytes = file.lengthSync() - 44;
          final ms = dataBytes / (sampleRate * channels * bits / 8) * 1000;
          expect(ms, closeTo(clip.durationMs, 5), reason: clip.asset);
        }
      }
    });
  });
}
