import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/widgets/loop/region_panel.dart';

/// AB 区間の一覧パネル: 行の表示、選択、メニュー、追加の上限、「全体」の有無
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  final regions = [
    LoopRegion(id: 'r1', name: 'サビ', pointAMs: 62000, pointBMs: 94000),
    LoopRegion(id: 'r2', name: '2番', pointAMs: 130000, pointBMs: null),
    LoopRegion(id: 'r3', name: '未設定の区間'),
  ];

  /// 呼ばれた回数は、戻した後も増えるようにリストで数える（int だと値のコピーになる）
  Future<({List<int> selected, List<int> menus, List<void> adds, List<void> closes, List<void> alls})> pump(
    WidgetTester tester, {
    required bool showAll,
    bool canAdd = true,
    int selectedIndex = 0,
  }) async {
    final selected = <int>[], menus = <int>[];
    final adds = <void>[], closes = <void>[], alls = <void>[];
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: RegionPanel(
            regions: regions,
            selectedIndex: selectedIndex,
            showAll: showAll,
            onSelectAll: () => alls.add(null),
            onSelect: selected.add,
            onMenu: menus.add,
            onAdd: canAdd ? () => adds.add(null) : null,
            onClose: () => closes.add(null),
          ),
        ),
      ),
    ));
    return (selected: selected, menus: menus, adds: adds, closes: closes, alls: alls);
  }

  testWidgets('行に名前と A–B(長さ)、未設定の表示', (tester) async {
    await pump(tester, showAll: false);
    expect(find.text('3 件'), findsOneWidget);
    expect(find.text('サビ'), findsOneWidget);
    expect(find.text('1:02 - 1:34 (32.0s)'), findsOneWidget);
    expect(find.text('2:10 - --:--'), findsOneWidget);
    expect(find.text('未設定'), findsOneWidget);
    expect(find.text('全体'), findsNothing);
  });

  testWidgets('showAll で「全体」が先頭に出てタップできる', (tester) async {
    final r = await pump(tester, showAll: true, selectedIndex: -1);
    expect(find.text('全体'), findsOneWidget);
    await tester.tap(find.text('全体'));
    expect(r.alls, hasLength(1));
    expect(r.selected, isEmpty);
  });

  testWidgets('行タップで選択、⋮ でメニュー、▾ で閉じる', (tester) async {
    final r = await pump(tester, showAll: false);
    await tester.tap(find.text('2番'));
    expect(r.selected, [1]);
    await tester.tap(find.byTooltip('リネーム・削除').at(2));
    expect(r.menus, [2]);
    await tester.tap(find.byTooltip('一覧を閉じる'));
    expect(r.closes, hasLength(1));
  });

  testWidgets('追加は上限で無効になる', (tester) async {
    final r = await pump(tester, showAll: false);
    await tester.tap(find.text('追加'));
    expect(r.adds, hasLength(1));

    await pump(tester, showAll: false, canAdd: false);
    expect(find.text('上限'), findsOneWidget);
    expect(find.text('追加'), findsNothing);
  });
}
