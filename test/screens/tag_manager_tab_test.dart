import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/screens/home/tag_manager_tab.dart';

/// タグタブのグリッド: 長押ししたまま動かすと並べ替え、動かさずに離すと長押し（複数選択）
void main() {
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    Hive.registerAdapter(TagAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
    await Hive.openBox<Tag>(AppBoxes.tagsName, bytes: Uint8List(0));
    // ヒントのカードは出さない（位置がずれないように）
    await AppBoxes.settings.put(SettingsKeys.tagOrderHintSeen, true);
  });
  tearDownAll(() => Hive.close());

  setUp(() async {
    await AppBoxes.tags.clear();
    for (final (i, name) in ['あ', 'い', 'う', 'え'].indexed) {
      await AppBoxes.tags.put('t$i', Tag(id: 't$i', name: name, order: i));
    }
  });

  Future<(ProviderContainer, List<String>)> pump(
      WidgetTester tester, TagViewMode mode,
      {bool selecting = false}) async {
    // タップで選択が切り替わったタグ（長押しでは呼ばれない）
    final longPressed = <String>[];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: TagManagerTab(
            viewMode: mode,
            selecting: selecting,
            selectedIds: const {'t0'},
            onToggleSelect: (t) => longPressed.add(t.id),
          ),
        ),
      ),
    ));
    return (container, longPressed);
  }

  List<String> names(ProviderContainer c) =>
      c.read(tagsProvider).map((t) => t.name).toList();

  for (final mode in [TagViewMode.grid2, TagViewMode.grid4]) {
    testWidgets('${mode.label}: 長押しで動かすと並べ替え', (tester) async {
      final (c, longPressed) = await pump(tester, mode);
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('あ')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getCenter(find.text('う')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(names(c), ['い', 'う', 'あ', 'え']);
      expect(longPressed, isEmpty);
    });

    testWidgets('${mode.label}: 長押しして動かさずに離しても何も起きない', (tester) async {
      final (c, longPressed) = await pump(tester, mode);
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('い')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(names(c), ['あ', 'い', 'う', 'え']);
      expect(longPressed, isEmpty);
    });

    testWidgets('${mode.label}: タップは選択の切り替え', (tester) async {
      final (_, toggled) = await pump(tester, mode);
      await tester.tap(find.text('い'));
      await tester.pumpAndSettle();
      expect(toggled, ['t1']);
    });
  }

  testWidgets('リスト: つまみを長押ししてから動かすと並べ替え（選択にはならない）', (tester) async {
    final (c, longPressed) = await pump(tester, TagViewMode.list);
    final handles = find.byIcon(Icons.drag_handle);
    final gesture = await tester.startGesture(tester.getCenter(handles.at(0)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(longPressed, isEmpty);
    final to = tester.getCenter(handles.at(2)) + const Offset(0, 20);
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(names(c), ['い', 'う', 'あ', 'え']);
    expect(longPressed, isEmpty);
  });

  testWidgets('リスト: ⋮ のメニューは行を隠さずに脇へ出る', (tester) async {
    await pump(tester, TagViewMode.list);
    final row = tester.getRect(
        find.ancestor(of: find.text('い'), matching: find.byType(ListTile)));
    await tester.tap(find.byIcon(Icons.more_vert).at(1));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.ancestor(
        of: find.text('名前を変更'),
        matching: find.byType(SingleChildScrollView)));
    expect(menu.overlaps(row), isFalse);
    expect(menu.top, greaterThanOrEqualTo(row.bottom));
    // 見出しに名前は出さない（行が見えている）
    expect(find.text('い'), findsOneWidget);

    // 外を押すと閉じる
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('名前を変更'), findsNothing);
  });

  testWidgets('リスト: つまみの列は右端も上下の端も並べ替え（選択にならない）', (tester) async {
    final (c, longPressed) = await pump(tester, TagViewMode.list);
    final row = tester.getRect(
        find.ancestor(of: find.text('あ'), matching: find.byType(ListTile)));
    for (final from in [
      Offset(row.right - 2, row.center.dy),
      Offset(row.right - 30, row.top + 2),
      Offset(row.right - 30, row.bottom - 2),
    ]) {
      final gesture = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
    }
    expect(longPressed, isEmpty);
    expect(names(c), ['あ', 'い', 'う', 'え']);

    // メニューのボタンは今まで通り押せる
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('名前を変更'), findsOneWidget);
  });

  testWidgets('リスト: タップは選択の切り替え、行の長押しは並べ替え', (tester) async {
    final (c, toggled) = await pump(tester, TagViewMode.list);
    await tester.tap(find.text('い'));
    await tester.pumpAndSettle();
    expect(toggled, ['t1']);
    toggled.clear();

    final gesture = await tester.startGesture(tester.getCenter(find.text('あ')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    final to = tester.getCenter(find.text('う')) + const Offset(0, 20);
    await gesture.moveTo(to - const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(names(c), ['い', 'う', 'あ', 'え']);
    expect(toggled, isEmpty);
  });

  for (final mode in TagViewMode.values) {
    testWidgets('${mode.label}: 選択に入っても名前の位置と大きさが変わらない', (tester) async {
      await pump(tester, mode);
      final before = [for (final n in ['あ', 'い']) tester.getRect(find.text(n))];
      await pump(tester, mode, selecting: true);
      await tester.pumpAndSettle();
      final after = [for (final n in ['あ', 'い']) tester.getRect(find.text(n))];
      expect(after, before);
    });
  }

  test('表示の保存値: 無ければ旧設定から', () {
    expect(TagViewMode.fromName('grid4'), TagViewMode.grid4);
    expect(TagViewMode.fromName(null), TagViewMode.list);
    expect(TagViewMode.fromName(null, legacyGrid: true), TagViewMode.grid2);
  });
}
