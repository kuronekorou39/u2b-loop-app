import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// サムネ画像の「色味」（色相）。再生画面の背景グラデーションに使う。
///
/// 画像を 24×24 に縮めて読み、彩度の高い画素ほど重くして色相の平均を取る。
/// 明るすぎ・暗すぎの画素（白い文字や黒い余白）は色味を持たないので軽くする。
/// 結果は色相だけ使い、明度・彩度は背景として落ち着く値に固定する（[ThumbTone.gradient]）。
class ThumbTone {
  const ThumbTone(this.hue);

  /// 0〜360
  final double hue;

  /// 背景用のグラデーション。上がサムネの色、下へ行くほど [base]（画面の地色）に沈む。
  /// ライトテーマでは淡い色にする
  List<Color> gradient(Color base, {bool dark = true}) => [
        HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.24 : 0.86).toColor(),
        HSLColor.fromAHSL(1, (hue + 35) % 360, 0.35, dark ? 0.13 : 0.92)
            .toColor(),
        base,
      ];

  /// 色味が取れなかったとき（サムネ無し・ほぼ無彩色）の既定
  static const fallback = ThumbTone(230);

  /// RGBA の画素列から色相を取る。無彩色ばかりなら null
  static ThumbTone? fromRgba(Uint8List rgba) {
    var sx = 0.0, sy = 0.0, weight = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final hsl = HSLColor.fromColor(
          Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]));
      // 彩度 × 中間の明るさ、で重み付け
      final mid = (1 - (hsl.lightness - 0.5).abs() * 2).clamp(0.0, 1.0);
      final w = hsl.saturation * mid;
      if (w < 0.05) continue;
      final rad = hsl.hue * pi / 180;
      sx += cos(rad) * w;
      sy += sin(rad) * w;
      weight += w;
    }
    final pixels = rgba.length ~/ 4;
    if (pixels == 0 || weight / pixels < 0.04) return null;
    var deg = atan2(sy, sx) * 180 / pi;
    if (deg < 0) deg += 360;
    return ThumbTone(deg);
  }

  static Future<ThumbTone?> fromFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes,
          targetWidth: 24, targetHeight: 24);
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (data == null) return null;
      return fromRgba(data.buffer.asUint8List());
    } catch (e) {
      debugPrint('[ThumbTone] 読めなかった: $path ($e)');
      return null;
    }
  }
}

/// サムネのパス → 色味。同じサムネは一度しか読まない
final thumbToneProvider = FutureProvider.family<ThumbTone?, String>(
    (ref, path) => ThumbTone.fromFile(path));
