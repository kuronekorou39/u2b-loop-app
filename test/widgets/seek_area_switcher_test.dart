import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/widgets/player/seek_area_switcher.dart';

/// シーク領域の切り替え: 高さが違っても下端を固定したまま滑らかに伸び縮みする
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 400,
                child: SeekAreaSwitcher(child: child),
              ),
            ),
          ),
        ),
      );

  const short = SizedBox(height: 100, width: double.infinity, key: Key('a'));
  const tall = SizedBox(height: 160, width: double.infinity, key: Key('b'));

  testWidgets('伸びる途中の高さは間の値。下端は動かず、入ってくる側は下端に揃う',
      (tester) async {
    await pump(tester, short);
    final area = find.byType(SeekAreaSwitcher);
    final before = tester.getRect(area);
    expect(before.height, 100);

    await pump(tester, tall);
    await tester.pump(const Duration(milliseconds: 125));
    final mid = tester.getRect(area);
    expect(mid.height, greaterThan(100));
    expect(mid.height, lessThan(160));
    expect(mid.bottom, before.bottom);
    expect(tester.getRect(find.byKey(const Key('b'))).bottom, before.bottom);
    expect(tester.getRect(find.byKey(const Key('a'))).bottom, before.bottom,
        reason: '出ていく側も下端に重ねる');

    await tester.pumpAndSettle();
    expect(tester.getRect(area).height, 160);
    expect(find.byKey(const Key('a')), findsNothing);
  });

  testWidgets('縮むときもすぐに縮み始める（フェードが終わるのを待たない）', (tester) async {
    await pump(tester, tall);
    final area = find.byType(SeekAreaSwitcher);
    final before = tester.getRect(area);
    await pump(tester, short);
    await tester.pump(const Duration(milliseconds: 125));
    final mid = tester.getRect(area);
    expect(mid.height, lessThan(160));
    expect(mid.height, greaterThan(100));
    expect(mid.bottom, before.bottom);
    await tester.pumpAndSettle();
    expect(tester.getRect(area).height, 100);
  });
}
