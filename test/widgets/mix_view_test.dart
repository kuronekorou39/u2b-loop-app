import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/mix_view.dart';

/// ミックスビューのシーク: タップ・ドラッグした x を時間軸（旧曲の時計）に直して返す。
/// 窓は start − 16s 〜 cut + 16s
void main() {
  const start = Duration(seconds: 100);
  const cut = Duration(seconds: 110);

  test('timeAtX は窓の左端が start − 16s、右端が cut + 16s', () {
    expect(
      MixView.timeAtX(0, 260, start: start, cut: cut),
      const Duration(seconds: 84),
    );
    expect(
      MixView.timeAtX(260, 260, start: start, cut: cut),
      const Duration(seconds: 126),
    );
    expect(
      MixView.timeAtX(130, 260, start: start, cut: cut),
      const Duration(seconds: 105),
    );
    // 外に出た分は端に丸める
    expect(
      MixView.timeAtX(-50, 260, start: start, cut: cut),
      const Duration(seconds: 84),
    );
    expect(
      MixView.timeAtX(999, 260, start: start, cut: cut),
      const Duration(seconds: 126),
    );
  });

  Future<List<Duration>> pump(
    WidgetTester tester, {
    bool seekable = true,
    Duration? prepLine,
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
                prepLine: prepLine,
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
    // 26px = 窓 42s の 1/10 ≈ 4.2s 進む
    expect(seeks.last.inMilliseconds, closeTo(109200, 200));
  });

  testWidgets('準備線が窓の中にあれば「次のつなぎへ」を描く（例外なし）', (tester) async {
    // 窓は 84s〜126s。線を 120s に置く
    final seeks = await pump(tester, prepLine: const Duration(seconds: 120));
    expect(find.byType(MixView), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 線の右（120s より後）を押しても、返る時刻はそのまま（扱いは呼び出し側）
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
}
