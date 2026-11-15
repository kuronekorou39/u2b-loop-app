import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/widgets/glass_controls.dart';

/// タブの選択の印: 緑の板 1 枚が横に滑る。動いている間は少し伸び、着くと元の幅
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  Future<TabController> pump(WidgetTester tester) async {
    final controller = TabController(length: 3, vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: GlassSegmentedTabs(
                  controller: controller,
                  labels: const ['タグ', '曲', 'プレイリスト'],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  Rect indicator(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('segment-indicator')));
  Rect label(WidgetTester tester, String text) => tester.getRect(
    find.ancestor(of: find.text(text), matching: find.byType(InkWell)),
  );

  testWidgets('タップすると板が滑って移る。途中は伸び、着くとタブと同じ幅', (tester) async {
    final controller = await pump(tester);
    expect(indicator(tester), label(tester, 'タグ'));
    final rest = indicator(tester).width;

    await tester.tap(find.text('プレイリスト'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final moving = indicator(tester);
    expect(moving.left, greaterThan(label(tester, 'タグ').left));
    expect(moving.right, lessThan(label(tester, 'プレイリスト').right));
    expect(moving.width, greaterThan(rest));
    // 出だしが速い: 時間の 2 割ほどで道のりの 4 割を越えている
    expect(controller.animation!.value, greaterThan(0.8));

    await tester.pumpAndSettle();
    final end = indicator(tester);
    expect(end.left, closeTo(label(tester, 'プレイリスト').left, 0.01));
    expect(end.width, closeTo(rest, 0.01));
    expect(controller.index, 2);
  });

  testWidgets('スワイプ中は指の位置に付いてくる', (tester) async {
    final controller = await pump(tester);
    controller.offset = 0.5;
    await tester.pump();
    final mid = indicator(tester);
    final a = label(tester, 'タグ');
    final b = label(tester, '曲');
    expect(mid.center.dx, closeTo((a.center.dx + b.center.dx) / 2, 0.01));
  });
}
