import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/sfx_library.dart';
import 'package:u2b_loop_app/core/audio/sfx_plan.dart';
import 'package:u2b_loop_app/widgets/player/mix_view.dart';

/// ミックスビュー（帯だけ）: 窓は交差の前後に余白を付けた範囲（= 重ね表示を出す範囲）。
/// タップ・ドラッグした x を時間軸（旧曲の時計）に直して返す。余白の段は親が「−」「＋」で変える
void main() {
  const start = Duration(seconds: 100);
  const cut = Duration(seconds: 110);
  const timelineEnd = Duration(seconds: 300);
  final initial = MixView.windowAround(
      start: start,
      cut: cut,
      margin: MixView.defaultMargin,
      timelineEnd: timelineEnd);
  // 帯のテスト用の広い窓（84s〜126s）
  final wide = MixView.windowAround(
      start: start,
      cut: cut,
      margin: const Duration(seconds: 16),
      timelineEnd: timelineEnd);

  test('最初の窓は start − 4s 〜 cut + 4s', () {
    expect(initial, const MixWindow(Duration(seconds: 96), Duration(seconds: 114)));
  });

  test('余白 0 なら交差そのもの。短い交差は 2s まで両側に広げる', () {
    expect(
      MixView.windowAround(
          start: start, cut: cut, margin: Duration.zero, timelineEnd: timelineEnd),
      const MixWindow(start, cut),
    );
    expect(
      MixView.windowAround(
          start: start,
          cut: start + const Duration(milliseconds: 500),
          margin: Duration.zero,
          timelineEnd: timelineEnd),
      const MixWindow(
          Duration(milliseconds: 99250), Duration(milliseconds: 101250)),
    );
  });

  test('窓は時間軸（0〜終わり）に収まる', () {
    expect(
      MixView.windowAround(
          start: const Duration(seconds: 5),
          cut: const Duration(seconds: 295),
          margin: const Duration(seconds: 16),
          timelineEnd: timelineEnd),
      const MixWindow(Duration.zero, timelineEnd),
    );
  });

  test('余白の段: 「＋」で 1 段狭く、「−」で 1 段広く。端では null', () {
    expect(MixView.narrower(MixView.defaultMargin), Duration.zero);
    expect(MixView.wider(MixView.defaultMargin), const Duration(seconds: 8));
    expect(MixView.narrower(Duration.zero), isNull);
    expect(MixView.wider(MixView.margins.last), isNull);
    // 段に無い値は、それ以上で最も近い段から数える
    expect(MixView.wider(const Duration(seconds: 5)), const Duration(seconds: 16));
  });

  test('timeAtX は窓の左端から右端まで。外に出た分は端に丸める', () {
    expect(MixView.timeAtX(0, 260, window: initial), const Duration(seconds: 96));
    expect(MixView.timeAtX(260, 260, window: initial), const Duration(seconds: 114));
    expect(MixView.timeAtX(130, 260, window: initial), const Duration(seconds: 105));
    expect(MixView.timeAtX(-50, 260, window: initial), const Duration(seconds: 96));
    expect(MixView.timeAtX(999, 260, window: initial), const Duration(seconds: 114));
  });

  Future<List<Duration>> pump(
    WidgetTester tester, {
    bool seekable = true,
    Duration now = const Duration(seconds: 95),
    BeatLineSource? beats,
    List<SfxCue> sfxCues = const [],
  }) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              // 帯は余白を持たないので、そのまま描画幅 260
              width: 260,
              child: MixView(
                outWaveform: const [0.5, 0.5],
                outDuration: const Duration(seconds: 120),
                outTitle: '出る曲',
                inWaveform: const [0.5, 0.5],
                inDuration: const Duration(seconds: 200),
                inStart: Duration.zero,
                inTitle: '入る曲',
                start: start,
                cut: cut,
                now: now,
                swapped: false,
                window: wide,
                height: 80,
                onSeek: seekable ? seeks.add : null,
                outBeats: beats,
                inBeats: beats,
                sfxCues: sfxCues,
              ),
            ),
          ),
        ),
      ),
    );
    return seeks;
  }

  testWidgets('タップとドラッグで onSeek が呼ばれる', (tester) async {
    final seeks = await pump(tester);
    final paint = find.descendant(
      of: find.byType(MixView),
      matching: find.byType(CustomPaint),
    );
    final rect = tester.getRect(paint);
    expect(rect.width, 260);

    await tester.tapAt(Offset(rect.left + 130, rect.center.dy));
    expect(seeks, [const Duration(seconds: 105)]);

    // MixView の Column は縦いっぱいに伸びるので、波形の面（CustomPaint）を起点にする
    await tester.drag(paint, const Offset(26, 0));
    expect(seeks.length, greaterThan(1));
    // 26px = 窓 42s の 1/10 ≈ 4.2s 進む
    expect(seeks.last.inMilliseconds, closeTo(109200, 200));
  });

  testWidgets('切替点より右を押しても、返る時刻はそのまま（例外なし）', (tester) async {
    // 窓は 84s〜126s
    final seeks = await pump(tester);
    expect(find.byType(MixView), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 扱いは呼び出し側
    final paint = find.descendant(
      of: find.byType(MixView),
      matching: find.byType(CustomPaint),
    );
    final rect = tester.getRect(paint);
    await tester.tapAt(Offset(rect.left + 250, rect.center.dy));
    expect(seeks.single.inMilliseconds, closeTo(124400, 200));
  });

  testWidgets('onSeek が無ければ触っても何も起きない', (tester) async {
    final seeks = await pump(tester, seekable: false);
    await tester.tap(
      find.descendant(
        of: find.byType(MixView),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(seeks, isEmpty);
  });

  testWidgets('効果音の印（ライザーの線・インパクトの点）を描ける', (tester) async {
    final riser = SfxLibrary.of(SfxRole.riser).first;
    final impact = SfxLibrary.of(SfxRole.impact).first;
    final cues = [
      SfxCue(clip: riser, atMs: 105000, rate: 1.2, bars: 2),
      SfxCue(clip: impact, atMs: 110000),
    ];
    await pump(tester, sfxCues: cues);
    expect(tester.takeException(), isNull);
    final paint = find.descendant(
      of: find.byType(MixView),
      matching: find.byType(CustomPaint),
    );
    // 画像にするのは本物の非同期処理なので runAsync の中で（テストの偽の時間では終わらない）
    Future<ByteData> shot() => tester.runAsync(() async {
          final image = await captureImage(tester.element(paint));
          return (await image.toByteData())!;
        }).then((v) => v!);
    final bytes = await shot();
    // 橙（効果音の色。赤 > 緑 ≫ 青）が描かれている。曲の色（赤は緑 = 青、水色は青が最大）とは混ざらない
    int orangeIn(ByteData px) {
      var n = 0;
      for (var i = 0; i < px.lengthInBytes; i += 4) {
        final r = px.getUint8(i), g = px.getUint8(i + 1), b = px.getUint8(i + 2);
        if (g > 20 && r > g && g > 1.8 * b) n++;
      }
      return n;
    }

    expect(orangeIn(bytes), greaterThan(20));
    // 印が無ければ橙は無い
    await pump(tester);
    expect(orangeIn(await shot()), 0);
  });

  testWidgets('拍の線を付けても描ける（交差の前後どちらの位置でも）', (tester) async {
    const beats = (
      grid: BeatGrid(
          bpm: 120, offsetMs: 0, downbeatMs: 500, downbeatConfidence: 1),
      anchorMs: null,
    );
    for (final now in const [
      Duration(seconds: 95),
      Duration(seconds: 105),
      Duration(seconds: 113),
    ]) {
      await pump(tester, now: now, beats: beats);
      expect(tester.takeException(), isNull);
    }
  });
}
