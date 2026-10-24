import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/jog_wheel.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  /// 円盤の中心（回せる円盤は Row の左端に円盤、その右にボタン）
  Offset discCenter(WidgetTester tester, {double size = 88}) =>
      tester.getTopLeft(find.byType(JogWheel)) + Offset(size / 2, size / 2);

  testWidgets('回すと値が変わり、離すと onChangeEnd が来る', (tester) async {
    double value = 0;
    bool? lastTouching;
    double? ended;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => JogWheel(
        periodMs: 500,
        valueMs: value,
        maxMs: 1000,
        onChanged: (ms, {required bool touching}) => setState(() {
          value = ms;
          lastTouching = touching;
        }),
        onChangeEnd: (ms) => ended = ms,
      ),
    )));

    final disc = discCenter(tester);
    // 中心の少し上から右へドラッグ＝時計回り→値が増える
    final gesture = await tester.startGesture(disc + const Offset(0, -24));
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(value, greaterThan(0));
    expect(lastTouching, isTrue);
    await gesture.up();
    await tester.pump();
    expect(ended, closeTo(value, 1e-9));
  });

  testWidgets('maxMs を超えない', (tester) async {
    double value = 0;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => JogWheel(
        periodMs: 500,
        valueMs: value,
        maxMs: 40,
        onChanged: (ms, {required bool touching}) => setState(() => value = ms),
        onChangeEnd: (_) {},
      ),
    )));
    final g = await tester.startGesture(discCenter(tester) + const Offset(0, -24));
    // 大きく回す（何周も）
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    await g.up();
    expect(value, lessThanOrEqualTo(40));
  });

  testWidgets('動かしていなければ保存・戻すは無効、中心に名前とずれが出る', (tester) async {
    await tester.pumpWidget(host(JogWheel(
      periodMs: 500,
      valueMs: 0,
      maxMs: 1000,
      errorMs: 8,
      onChanged: (ms, {required bool touching}) {},
      onChangeEnd: (_) {},
      onSave: null,
      onReset: null,
    )));
    expect(find.textContaining('次曲'), findsOneWidget);
    expect(find.textContaining('ずれ +8'), findsOneWidget);
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.push_pin_outlined));
    expect(save.onPressed, isNull);
    final reset =
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh));
    expect(reset.onPressed, isNull);
  });

  testWidgets('動かしていれば量を出し、保存・戻すが押せる', (tester) async {
    var saved = 0, reset = 0;
    await tester.pumpWidget(host(JogWheel(
      periodMs: 500,
      valueMs: -18,
      maxMs: 1000,
      onChanged: (ms, {required bool touching}) {},
      onChangeEnd: (_) {},
      onSave: () => saved++,
      onReset: () => reset++,
    )));
    expect(find.textContaining('−18ms'), findsOneWidget);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.push_pin_outlined));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
    expect(saved, 1);
    expect(reset, 1);
  });

  testWidgets('表示だけの円盤（前曲）はボタンが無く、触っても下に落ちない', (tester) async {
    var behind = 0;
    await tester.pumpWidget(host(Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => behind++,
          ),
        ),
        Center(
          child: JogWheel.platter(turns: JogWheel.platterTurns(
              const Duration(seconds: 9))),
        ),
      ],
    )));
    expect(find.text('前曲'), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    // 円盤の上を押しても、下のタップにならない
    await tester.tap(find.byType(JogWheel));
    expect(behind, 0);
    // 1.8 秒で 1 周
    expect(JogWheel.platterTurns(const Duration(milliseconds: 1800)), 1);
  });
}
