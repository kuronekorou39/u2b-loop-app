import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/mix_view.dart';

/// ミックスビューのシーク: タップ・ドラッグした x を時間軸（旧曲の時計）に直して返す。
/// 窓は start − 8s 〜 cut + 8s
void main() {
  const start = Duration(seconds: 100);
  const cut = Duration(seconds: 110);

  test('timeAtX は窓の左端が start − 8s、右端が cut + 8s', () {
    expect(
      MixView.timeAtX(0, 260, start: start, cut: cut),
      const Duration(seconds: 92),
    );
    expect(
      MixView.timeAtX(260, 260, start: start, cut: cut),
      const Duration(seconds: 118),
    );
    expect(
      MixView.timeAtX(130, 260, start: start, cut: cut),
      const Duration(seconds: 105),
    );
    // 外に出た分は端に丸める
    expect(
      MixView.timeAtX(-50, 260, start: start, cut: cut),
      const Duration(seconds: 92),
    );
    expect(
      MixView.timeAtX(999, 260, start: start, cut: cut),
      const Duration(seconds: 118),
    );
  });

  Future<List<Duration>> pump(
    WidgetTester tester, {
    bool seekable = true,
  }) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              // 横の余白 16×2 を引いて描画幅が 260 になる
              width: 292,
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
                now: const Duration(seconds: 95),
                swapped: false,
                height: 80,
                onSeek: seekable ? seeks.add : null,
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
    // 26px = 窓 26s の 1/10 = 2.6s 進む
    expect(seeks.last.inMilliseconds, closeTo(107600, 200));
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
}
