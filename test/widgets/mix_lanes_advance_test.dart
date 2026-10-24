import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/mix_lanes_advance.dart';

/// 棒 2 本と帯の入れ替え: またぐ線が消え、前曲の段は左へ抜け、次曲の段は上がり、
/// 新しい次曲の段は右から入り、最後にまたぐ線が出る
void main() {
  Widget part(String name, double height) => SizedBox(
        key: ValueKey(name),
        width: double.infinity,
        height: height,
        child: const ColoredBox(color: Colors.white),
      );

  // 帯を作るたびに渡された線の濃さ（組ごと）
  final lines = <String, double>{};

  Widget host(String pair) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: MixLanesAdvance(
                pairKey: ValueKey(pair),
                topBar: part('top$pair', 20),
                band: (opacity) {
                  lines[pair] = opacity;
                  return part('band$pair', 96);
                },
                bottomBar: part('bottom$pair', 28),
                topBarHeight: 20,
                bandHeight: 96,
                bottomBarHeight: 28,
              ),
            ),
          ),
        ),
      );

  setUp(lines.clear);

  testWidgets('動いていないときは縦に並ぶだけ。線は濃いまま', (tester) async {
    await tester.pumpWidget(host('a'));
    expect(tester.getTopLeft(find.byKey(const ValueKey('topa'))).dy, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('banda'))).dy, 24);
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottoma'))).dy, 124);
    expect(tester.getSize(find.byType(MixLanesAdvance)).height, 152);
    expect(lines['a'], 1);
  });

  testWidgets('組が進むと、線が消え、前曲の棒は左へ、次曲の棒は上へ、新しい次曲の棒は右から、最後に線',
      (tester) async {
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('b'));
    // 線が消える（0〜150ms）。段はまだ動かない
    await tester.pump(const Duration(milliseconds: 75));
    expect(lines['a'], lessThan(1));
    expect(lines['a'], greaterThan(0));
    expect(lines['b'], 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('topa'))).dx, 0);
    // 前曲の棒が左へ抜けていく（150〜400ms）。次曲の棒はまだそのまま。線は消えた
    await tester.pump(const Duration(milliseconds: 200));
    expect(lines['a'], 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('topa'))).dx, lessThan(0));
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottoma'))).dy, 124);
    // 次曲の棒が上がっていく（400〜700ms）。新しい次曲の棒は右の外
    await tester.pump(const Duration(milliseconds: 275));
    expect(find.byKey(const ValueKey('topa')), findsNothing);
    final rising = tester.getTopLeft(find.byKey(const ValueKey('bottoma'))).dy;
    expect(rising, lessThan(124));
    expect(rising, greaterThan(0));
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottomb'))).dx, 300);
    // 新しい次曲の棒が右から入ってくる（700〜1000ms）。線はまだ
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('bottoma')), findsNothing);
    final entering = tester.getTopLeft(find.byKey(const ValueKey('bottomb'))).dx;
    expect(entering, greaterThan(0));
    expect(entering, lessThan(300));
    expect(lines['b'], 0);
    // 線が出る（1000〜1200ms）
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottomb'))).dx, 0);
    expect(lines['b'], greaterThan(0));
    expect(lines['b'], lessThan(1));

    await tester.pumpAndSettle();
    expect(lines['b'], 1);
    expect(tester.getTopLeft(find.byKey(const ValueKey('topb'))), Offset.zero);
    expect(tester.getTopLeft(find.byKey(const ValueKey('bottomb'))), const Offset(0, 124));
    // 動き終わったら帯は 1 枚
    expect(find.byKey(const ValueKey('bandb')), findsOneWidget);
    expect(tester.getSize(find.byType(MixLanesAdvance)).height, 152);
    expect(tester.takeException(), isNull);
  });
}
