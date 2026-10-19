import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/mix_view.dart';

/// ミックスビュー: タップ・ドラッグした x を時間軸（旧曲の時計）に直して返す。
/// 最初の窓は start − 16s 〜 cut + 16s。拡大縮小は「−」「＋」「交差」「全体」、
/// 見る場所はミニマップのドラッグで動かす
void main() {
  const start = Duration(seconds: 100);
  const cut = Duration(seconds: 110);
  const timelineEnd = Duration(seconds: 300);
  final initial = MixView.initialWindow(
      start: start, cut: cut, timelineEnd: timelineEnd);

  test('最初の窓は start − 16s 〜 cut + 16s', () {
    expect(initial, const MixWindow(Duration(seconds: 84), Duration(seconds: 126)));
  });

  test('timeAtX は窓の左端から右端まで。外に出た分は端に丸める', () {
    expect(MixView.timeAtX(0, 260, window: initial), const Duration(seconds: 84));
    expect(MixView.timeAtX(260, 260, window: initial), const Duration(seconds: 126));
    expect(MixView.timeAtX(130, 260, window: initial), const Duration(seconds: 105));
    expect(MixView.timeAtX(-50, 260, window: initial), const Duration(seconds: 84));
    expect(MixView.timeAtX(999, 260, window: initial), const Duration(seconds: 126));
  });

  test('窓は時間軸と幅の下限に収まる', () {
    final minSpan = MixView.minSpan(start, cut); // 交差 10s
    expect(minSpan, const Duration(seconds: 10));
    // 短すぎる交差でも 2s までしか寄せない
    expect(MixView.minSpan(start, start + const Duration(milliseconds: 500)),
        MixView.minSpanFloor);
    // 右にはみ出したら左へずらす
    expect(
      MixView.clampWindow(
          const MixWindow(Duration(seconds: 290), Duration(seconds: 330)),
          minSpan: minSpan, timelineEnd: timelineEnd),
      const MixWindow(Duration(seconds: 260), Duration(seconds: 300)),
    );
    // 幅が全体より広ければ全体
    expect(
      MixView.clampWindow(
          const MixWindow(Duration(seconds: -50), Duration(seconds: 500)),
          minSpan: minSpan, timelineEnd: timelineEnd),
      MixView.wholeWindow(timelineEnd),
    );
  });

  test('「交差」は重なりがぴったり、「全体」は 0 から終わりまで', () {
    expect(
      MixView.crossfadeWindow(start: start, cut: cut, timelineEnd: timelineEnd),
      const MixWindow(start, cut),
    );
    expect(MixView.wholeWindow(timelineEnd),
        const MixWindow(Duration.zero, timelineEnd));
  });

  test('「−」は再生位置を動かさずに幅を倍に、「＋」で戻る', () {
    final minSpan = MixView.minSpan(start, cut);
    const now = Duration(seconds: 105); // 窓の真ん中
    final out = MixView.zoomed(initial, 2,
        around: now, minSpan: minSpan, timelineEnd: timelineEnd);
    expect(out.span, const Duration(seconds: 84));
    expect(out.start + out.span ~/ 2, now);
    final back = MixView.zoomed(out, 0.5,
        around: now, minSpan: minSpan, timelineEnd: timelineEnd);
    expect(back, initial);
    // 寄せ切ったら交差の幅より狭くならない
    final tight = MixView.zoomed(initial, 0.01,
        around: now, minSpan: minSpan, timelineEnd: timelineEnd);
    expect(tight.span, minSpan);
  });

  test('「現在地へ」は幅そのままで再生位置が真ん中に', () {
    final w = MixView.centeredOn(const Duration(seconds: 200),
        span: initial.span,
        minSpan: MixView.minSpan(start, cut),
        timelineEnd: timelineEnd);
    expect(w, const MixWindow(Duration(seconds: 179), Duration(seconds: 221)));
  });

  Future<List<Duration>> pump(
    WidgetTester tester, {
    bool seekable = true,
    Duration? prepLine,
    Duration now = const Duration(seconds: 95),
    List<MixWindow>? windows,
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
                now: now,
                swapped: false,
                window: initial,
                timelineEnd: timelineEnd,
                onWindowChanged: windows?.add,
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

  testWidgets('「−」「＋」と範囲のピル「交差」「前後」「全体」で窓が変わる', (tester) async {
    final windows = <MixWindow>[];
    await pump(tester, windows: windows);
    await tester.tap(find.text('全体'));
    expect(windows.last, MixView.wholeWindow(timelineEnd));
    await tester.tap(find.text('交差'));
    expect(windows.last, const MixWindow(start, cut));
    await tester.tap(find.text('前後'));
    expect(windows.last, initial);
    await tester.tap(find.byIcon(Icons.remove));
    expect(windows.last.span, const Duration(seconds: 84));
    await tester.tap(find.byIcon(Icons.add));
    expect(windows.last.span, const Duration(seconds: 21));
  });

  testWidgets('再生位置が窓の外なら「現在地」が出て、押すと真ん中に来る', (tester) async {
    final windows = <MixWindow>[];
    await pump(tester, windows: windows, now: const Duration(seconds: 200));
    expect(find.text('現在地'), findsOneWidget);
    await tester.tap(find.text('現在地'));
    final w = windows.single;
    expect(w.start + w.span ~/ 2, const Duration(seconds: 200));
    expect(w.span, initial.span);
  });

  testWidgets('再生位置が窓の中なら「現在地」は出ない', (tester) async {
    await pump(tester, windows: <MixWindow>[]);
    expect(find.text('現在地'), findsNothing);
  });
}
