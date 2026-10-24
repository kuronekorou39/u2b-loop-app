import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/advance_stage.dart';

/// 3 拍子の土台: key が変わったら前の値を渡して、抜ける → 上がる → 入る の順に進む
void main() {
  testWidgets('key が変わると前の値が来て、3 拍子が順に進み、終わると前の値は消える',
      (tester) async {
    String? previous;
    AdvancePhases? phases;
    Widget host(String value, Key key) => MaterialApp(
          home: AdvanceStage<String>(
            stageKey: key,
            value: value,
            builder: (context, current, prev, p) {
              previous = prev;
              phases = p;
              return Text('$current/${prev ?? '-'}');
            },
          ),
        );
    await tester.pumpWidget(host('a', const ValueKey(1)));
    expect(previous, isNull);
    expect(phases, AdvanceStage.done);

    await tester.pumpWidget(host('b', const ValueKey(2)));
    await tester.pump();
    expect(previous, 'a');
    expect(find.text('b/a'), findsOneWidget);
    // 1 拍目: 抜けるだけが進む
    await tester.pump(const Duration(milliseconds: 135));
    expect(phases!.leave, greaterThan(0));
    expect(phases!.leave, lessThan(1));
    expect(phases!.rise, 0);
    expect(phases!.enter, 0);
    // 2 拍目: 抜け終わって、上がる途中
    await tester.pump(const Duration(milliseconds: 315));
    expect(phases!.leave, 1);
    expect(phases!.rise, greaterThan(0));
    expect(phases!.rise, lessThan(1));
    expect(phases!.enter, 0);
    // 3 拍目: 入る途中
    await tester.pump(const Duration(milliseconds: 270));
    expect(phases!.rise, 1);
    expect(phases!.enter, greaterThan(0));
    expect(phases!.enter, lessThan(1));

    await tester.pumpAndSettle();
    expect(previous, isNull);
    expect(phases, AdvanceStage.done);
    expect(find.text('b/-'), findsOneWidget);
  });

  testWidgets('同じ key なら値を差し替えるだけで動かない', (tester) async {
    String? previous;
    Widget host(String value) => MaterialApp(
          home: AdvanceStage<String>(
            stageKey: const ValueKey(1),
            value: value,
            builder: (context, current, prev, p) {
              previous = prev;
              return Text(current);
            },
          ),
        );
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('b'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(previous, isNull);
    expect(find.text('b'), findsOneWidget);
  });
}
