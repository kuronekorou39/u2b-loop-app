import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_state.dart';
import 'package:u2b_loop_app/widgets/loop/ab_edit_controls.dart';

/// AB 編集ブロック: − / + がステップぶん動かす、時刻タップでシーク、
/// A > B のときだけ入れ替えが出る、ステップの切替
void main() {
  Future<({List<Duration> a, List<Duration> b, List<Duration> seeks, List<double> steps, int swaps})> pump(
    WidgetTester tester, {
    required LoopState loop,
    double step = 0.1,
    bool compact = false,
  }) async {
    final a = <Duration>[], b = <Duration>[], seeks = <Duration>[], steps = <double>[];
    var swaps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          child: AbEditControls(
            loop: loop,
            step: step,
            onStepChanged: steps.add,
            onSeek: seeks.add,
            onPointA: a.add,
            onPointB: b.add,
            onSwap: () => swaps++,
            onSetA: () {},
            onSetB: () {},
            compact: compact,
          ),
        ),
      ),
    ));
    return (a: a, b: b, seeks: seeks, steps: steps, swaps: swaps);
  }

  const loop = LoopState(
    enabled: true,
    pointA: Duration(seconds: 62),
    pointB: Duration(seconds: 94),
  );

  testWidgets('− / + はステップぶん A/B を動かす', (tester) async {
    final r = await pump(tester, loop: loop, step: 0.1);
    await tester.tap(find.byTooltip('A を進める'));
    await tester.tap(find.byTooltip('B を戻す'));
    expect(r.a, [const Duration(milliseconds: 62100)]);
    expect(r.b, [const Duration(milliseconds: 93900)]);
  });

  testWidgets('時刻タップでその位置へシーク', (tester) async {
    final r = await pump(tester, loop: loop);
    await tester.tap(find.text('1:02.000'));
    expect(r.seeks, [const Duration(seconds: 62)]);
  });

  testWidgets('A > B のときだけ入れ替えが出る', (tester) async {
    await pump(tester, loop: loop);
    expect(find.text('A と B を入れ替え'), findsNothing);

    await pump(
        tester,
        loop: const LoopState(
            pointA: Duration(seconds: 90), pointB: Duration(seconds: 10)));
    expect(find.text('A と B を入れ替え'), findsOneWidget);
  });

  testWidgets('未設定の点は − / + が無効', (tester) async {
    final r = await pump(tester, loop: const LoopState(pointA: Duration(seconds: 5)));
    await tester.tap(find.byTooltip('B を進める'), warnIfMissed: false);
    expect(r.b, isEmpty);
    expect(find.text('--:--.---'), findsOneWidget);
  });

  testWidgets('ステップのピルで切り替える', (tester) async {
    final r = await pump(tester, loop: loop, step: 0.1);
    await tester.tap(find.text('1s'));
    await tester.tap(find.text('0.01s'));
    expect(r.steps, [1.0, 0.01]);
  });

  testWidgets('compact でも同じ操作ができる', (tester) async {
    final r = await pump(tester, loop: loop, step: 1.0, compact: true);
    await tester.tap(find.byTooltip('A を戻す'));
    expect(r.a, [const Duration(seconds: 61)]);
  });
}
