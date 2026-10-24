import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/advance_stage.dart';

/// 5 拍子の土台: key が変わったら前の値を渡して、
/// 線が消える → 抜ける → 上がる → 入る → 線が出る の順に進む
void main() {
  testWidgets('key が変わると前の値が来て、5 拍子が順に進み、終わると前の値は消える',
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

    bool mid(double v) => v > 0 && v < 1;
    // 1.2 秒: 線が消える 0〜150ms
    await tester.pump(const Duration(milliseconds: 75));
    expect(mid(phases!.hide), isTrue);
    expect(phases!.leave, 0);
    expect(AdvanceStage.hidingOpacity(phases!), 1 - phases!.hide);
    expect(AdvanceStage.showingOpacity(phases!), 0);
    // 抜ける 150〜400ms
    await tester.pump(const Duration(milliseconds: 250));
    expect(phases!.hide, 1);
    expect(mid(phases!.leave), isTrue);
    expect(phases!.rise, 0);
    // 上がる 400〜700ms
    await tester.pump(const Duration(milliseconds: 300));
    expect(phases!.leave, 1);
    expect(mid(phases!.rise), isTrue);
    expect(phases!.enter, 0);
    // 入る 700〜1000ms
    await tester.pump(const Duration(milliseconds: 250));
    expect(phases!.rise, 1);
    expect(mid(phases!.enter), isTrue);
    expect(phases!.show, 0);
    // 線が出る 1000〜1200ms
    await tester.pump(const Duration(milliseconds: 225));
    expect(phases!.enter, 1);
    expect(mid(phases!.show), isTrue);
    expect(AdvanceStage.showingOpacity(phases!), phases!.show);

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
