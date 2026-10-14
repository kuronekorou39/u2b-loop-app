import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/providers/thumb_tone_provider.dart';

/// RGBA の画素列を作る
Uint8List _pixels(List<Color> colors) {
  final out = Uint8List(colors.length * 4);
  for (var i = 0; i < colors.length; i++) {
    final c = colors[i];
    out[i * 4] = (c.r * 255).round();
    out[i * 4 + 1] = (c.g * 255).round();
    out[i * 4 + 2] = (c.b * 255).round();
    out[i * 4 + 3] = 255;
  }
  return out;
}

void main() {
  group('ThumbTone.fromRgba', () {
    test('一色の画像ならその色相', () {
      final tone = ThumbTone.fromRgba(_pixels(
          List.filled(16, HSLColor.fromAHSL(1, 200, 0.7, 0.5).toColor())));
      expect(tone, isNotNull);
      expect(tone!.hue, closeTo(200, 2));
    });

    test('白・黒・グレーだけなら色味なし', () {
      final tone = ThumbTone.fromRgba(_pixels([
        Colors.white,
        Colors.black,
        Colors.grey,
        const Color(0xFF202020),
      ]));
      expect(tone, isNull);
    });

    test('白い文字が多くても、彩度のある部分の色相を拾う', () {
      final tone = ThumbTone.fromRgba(_pixels([
        ...List.filled(10, Colors.white),
        ...List.filled(6, HSLColor.fromAHSL(1, 30, 0.8, 0.5).toColor()),
      ]));
      expect(tone, isNotNull);
      expect(tone!.hue, closeTo(30, 2));
    });

    test('赤寄り（350°）と赤（10°）の平均は 0° をまたいで 0 付近', () {
      final tone = ThumbTone.fromRgba(_pixels([
        HSLColor.fromAHSL(1, 350, 0.8, 0.5).toColor(),
        HSLColor.fromAHSL(1, 10, 0.8, 0.5).toColor(),
      ]));
      expect(tone, isNotNull);
      final h = tone!.hue;
      expect(h < 5 || h > 355, isTrue, reason: 'hue=$h');
    });

    test('空なら null', () {
      expect(ThumbTone.fromRgba(Uint8List(0)), isNull);
    });
  });

  test('gradient は 3 色で、最後が地色', () {
    const base = Color(0xFF1A1A2E);
    final g = const ThumbTone(120).gradient(base);
    expect(g.length, 3);
    expect(g.last, base);
    // ライトテーマは淡い
    final light = const ThumbTone(120).gradient(Colors.white, dark: false);
    expect(HSLColor.fromColor(light.first).lightness, greaterThan(0.8));
  });
}
