import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/mix_lanes_advance.dart';

/// 棒 2 本と帯の入れ替え: 前曲の段は左へ抜け、次曲の段は上がり、新しい次曲の段は右から
void main() {
  Widget part(String name, double height) => SizedBox(
        key: ValueKey(name),
        width: double.infinity,
        height: height,
        child: const ColoredBox(color: Colors.white),
      );

  Widget host(String pair) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: MixLanesAdvance(
                pairKey: ValueKey(pair),
                topBar: part('top$pair', 20),
                band: part('band$pair', 96),
                bottomBar: part('bottom$pair', 28),
                topBarHeight: 20,
                bandHeight: 96,
                bottomBarHeight: 28,
              ),
            ),
          ),
        ),
      );

  testWidgets('動いていないときは縦に並ぶだけ', (tester) async {
    await tester.pumpWidget(host('a'));
    expect(tester.getTopLeft(find.byKey(const ValueKey('topa'))).dy, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('banda'))).dy, 24);
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottoma'))).dy, 124);
    expect(tester.getSize(find.byType(MixLanesAdvance)).height, 152);
  });

  testWidgets('組が進むと、前曲の棒は左へ、次曲の棒は上へ、新しい次曲の棒は右から', (tester) async {
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('b'));
    // 1 拍目: 前曲の棒が左へ抜けていく。次曲の棒はまだそのまま
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(find.byKey(const ValueKey('topa'))).dx, lessThan(0));
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottoma'))).dy, 124);
    // 2 拍目: 次曲の棒が上がっていく。新しい次曲の棒は右の外
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('topa')), findsNothing);
    final rising = tester.getTopLeft(find.byKey(const ValueKey('bottoma'))).dy;
    expect(rising, lessThan(124));
    expect(rising, greaterThan(0));
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottomb'))).dx, 300);
    // 3 拍目: 新しい次曲の棒が右から入ってくる
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('bottoma')), findsNothing);
    final entering = tester.getTopLeft(find.byKey(const ValueKey('bottomb'))).dx;
    expect(entering, greaterThan(0));
    expect(entering, lessThan(300));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const ValueKey('topb'))), Offset.zero);
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottomb'))), const Offset(0, 124));
    // 動き終わったら帯は 1 枚
    expect(find.byKey(const ValueKey('bandb')), findsOneWidget);
    expect(tester.getSize(find.byType(MixLanesAdvance)).height, 152);
    expect(tester.takeException(), isNull);
  });
}
