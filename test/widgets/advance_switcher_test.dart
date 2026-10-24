import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/advance_switcher.dart';

/// 組が次へ進むときの切り替え: 出る側は進む向きへ抜け、入る側は反対側から入る
void main() {
  Widget host(Widget child, {AxisDirection direction = AxisDirection.up}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: AdvanceSwitcher(direction: direction, child: child),
            ),
          ),
        ),
      );
  const a = ValueKey('a');
  const b = ValueKey('b');

  testWidgets('key が変わると、出る側は上へ抜け、入る側は下から上がってくる', (tester) async {
    await tester.pumpWidget(host(const SizedBox.expand(key: a)));
    final rest = tester.getCenter(find.byKey(a));

    await tester.pumpWidget(host(const SizedBox.expand(key: b)));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getCenter(find.byKey(a)).dy, lessThan(rest.dy));
    expect(tester.getCenter(find.byKey(b)).dy, greaterThan(rest.dy));
    expect(tester.getCenter(find.byKey(b)).dx, rest.dx);

    await tester.pumpAndSettle();
    expect(find.byKey(a), findsNothing);
    expect(tester.getCenter(find.byKey(b)), rest);
  });

  testWidgets('左向きなら出る側は左へ、入る側は右から', (tester) async {
    await tester.pumpWidget(
        host(const SizedBox.expand(key: a), direction: AxisDirection.left));
    final rest = tester.getCenter(find.byKey(a));
    await tester.pumpWidget(
        host(const SizedBox.expand(key: b), direction: AxisDirection.left));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getCenter(find.byKey(a)).dx, lessThan(rest.dx));
    expect(tester.getCenter(find.byKey(b)).dx, greaterThan(rest.dx));
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.byKey(b)), rest);
  });

  testWidgets('同じ key なら差し替えるだけで動かない', (tester) async {
    await tester.pumpWidget(host(const SizedBox.expand(key: a)));
    final rest = tester.getCenter(find.byKey(a));
    // 同じ型・同じ key なら差し替え（型が違えば別の子として動く）
    await tester.pumpWidget(host(const SizedBox.expand(
        key: a, child: ColoredBox(color: Colors.red))));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(a), findsOneWidget);
    expect(tester.getCenter(find.byKey(a)), rest);
    expect(
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == Colors.red),
        findsOneWidget);
  });
}
