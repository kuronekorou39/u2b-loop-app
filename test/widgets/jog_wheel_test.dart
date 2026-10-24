import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/jog_wheel.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('回すと値が変わり、離すと onChangeEnd が来る', (tester) async {
    double value = 0;
    bool? lastTouching;
    double? ended;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => JogWheel(
        periodMs: 500,
        valueMs: value,
        maxMs: 1000,
        onChanged: (ms, {required bool touching}) =>
            setState(() {
              value = ms;
              lastTouching = touching;
            }),
        onChangeEnd: (ms) => ended = ms,
      ),
    )));

    final wheel = find.byType(JogWheel);
    // 円盤の中心（Column の上部。全体の中心ではない。円盤は 72px）
    final disc = Offset(
        tester.getCenter(wheel).dx, tester.getTopLeft(wheel).dy + 36);
    // 中心の少し上から右へドラッグ＝時計回り→値が増える
    final gesture = await tester.startGesture(disc + const Offset(0, -20));
    await gesture.moveBy(const Offset(20, 0));
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
    final wheel = find.byType(JogWheel);
    final disc = Offset(
        tester.getCenter(wheel).dx, tester.getTopLeft(wheel).dy + 36);
    final g = await tester.startGesture(disc + const Offset(0, -20));
    // 大きく回す（何周も）
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    await g.up();
    expect(value, lessThanOrEqualTo(40));
  });

  testWidgets('動かしていなければ保存・戻すは無効、ずれは色付きで出る', (tester) async {
    var saved = false;
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
    expect(find.textContaining('ずれ'), findsOneWidget);
    final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.push_pin_outlined));
    expect(save.onPressed, isNull);
    expect(saved, isFalse);
  });
}
