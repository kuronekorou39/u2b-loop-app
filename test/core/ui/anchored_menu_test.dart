import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/ui/anchored_menu.dart';
import 'package:u2b_loop_app/screens/home/home_parts.dart';

Future<Rect> _openMenu(WidgetTester tester, Size screen, Rect anchor) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(AnchoredMenuRoute<void>(
          anchorRect: anchor,
          builder: (_) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 12; i++)
                  const SizedBox(height: 48, child: Text('行')),
              ],
            ),
          ),
        )),
        child: const Text('開く'),
      ),
    ),
  ));
  await tester.tap(find.text('開く'));
  await tester.pumpAndSettle();
  return tester.getRect(find
      .ancestor(of: find.text('行').first, matching: find.byType(Material))
      .first);
}

void main() {
  testWidgets('縦画面のボタンのメニューはボタンのすぐ下に出る', (tester) async {
    const button = Rect.fromLTWH(340, 40, 48, 48);
    final menu = await _openMenu(tester, const Size(400, 800), button);
    expect(menu.top, greaterThanOrEqualTo(button.bottom));
    expect(menu.overlaps(button), isFalse);
  });

  testWidgets('画面の下のボタンのメニューはボタンの上に出る', (tester) async {
    const button = Rect.fromLTWH(200, 720, 60, 40);
    final menu = await _openMenu(tester, const Size(400, 800), button);
    expect(menu.bottom, lessThanOrEqualTo(button.top));
  });

  testWidgets('横画面のボタンのメニューは左の脇に出て、はみ出さない', (tester) async {
    const button = Rect.fromLTWH(790, 8, 48, 48);
    const screen = Size(850, 400);
    final menu = await _openMenu(tester, screen, button);
    expect(menu.right, lessThanOrEqualTo(button.left));
    expect(menu.overlaps(button), isFalse);
    expect(menu.top, greaterThanOrEqualTo(0));
    expect(menu.bottom, lessThanOrEqualTo(screen.height));
  });

  testWidgets('横画面で左端のボタンのメニューは右の脇に出る', (tester) async {
    const button = Rect.fromLTWH(10, 300, 48, 48);
    const screen = Size(850, 400);
    final menu = await _openMenu(tester, screen, button);
    expect(menu.left, greaterThanOrEqualTo(button.right));
    expect(menu.bottom, lessThanOrEqualTo(screen.height));
  });

  testWidgets('ホームのリストは広い画面で幅を抑えて真ん中に置く', (tester) async {
    tester.view.physicalSize = const Size(1000, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const key = Key('list');
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: HomeListSurface(child: SizedBox.expand(key: key)),
      ),
    ));
    final rect = tester.getRect(find.byKey(key));
    expect(rect.width, lessThanOrEqualTo(HomeListSurface.maxWidth));
    expect(rect.center.dx, closeTo(500, 0.5));
  });
}
