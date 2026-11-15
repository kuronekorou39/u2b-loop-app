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

/// タグタブ: タップも長押しも選択。並べ替えは並べ替えモードの中だけ
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

  /// 戻り値の 2 つ目は、選択が切り替わったタグ
  Future<(ProviderContainer, List<String>)> pump(
      WidgetTester tester, TagViewMode mode,
      {bool selecting = false, bool reordering = false}) async {
    final toggled = <String>[];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: TagManagerTab(
            viewMode: mode,
            selecting: selecting,
            reordering: reordering,
            selectedIds: const {'t0'},
            onToggleSelect: (t) => toggled.add(t.id),
          ),
        ),
      ),
    ));
    return (container, toggled);
  }

  List<String> names(ProviderContainer c) =>
      c.read(tagsProvider).map((t) => t.name).toList();

  /// 少しずつ動かす（行が場所を譲るアニメーションを進めながら）
  Future<void> slide(
      WidgetTester tester, TestGesture gesture, Offset from, Offset to) async {
    for (var k = 1; k <= 10; k++) {
      await gesture.moveTo(Offset.lerp(from, to, k / 10)!);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 長押ししてから [to] まで動かして離す
  Future<void> holdAndDrag(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await slide(tester, gesture, from, to);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  for (final mode in [TagViewMode.grid2, TagViewMode.grid4]) {
    testWidgets('${mode.label}: 並べ替えモードは長押しで動かすと並べ替え（選択しない）', (tester) async {
      final (c, toggled) = await pump(tester, mode, reordering: true);
      await holdAndDrag(tester, tester.getCenter(find.text('あ')),
          tester.getCenter(find.text('う')));
      expect(names(c), ['い', 'う', 'あ', 'え']);
      await tester.tap(find.text('い'));
      await tester.pumpAndSettle();
      expect(toggled, isEmpty);
    });

    testWidgets('${mode.label}: ふだんはタップも長押しも選択。動かしても並びは変わらない', (tester) async {
      final (c, toggled) = await pump(tester, mode);
      await tester.tap(find.text('い'));
      await tester.pumpAndSettle();
      expect(toggled, ['t1']);
      await tester.longPress(find.text('う'));
      await tester.pumpAndSettle();
      expect(toggled, ['t1', 't2']);
      await holdAndDrag(tester, tester.getCenter(find.text('あ')),
          tester.getCenter(find.text('う')));
      expect(names(c), ['あ', 'い', 'う', 'え']);
    });
  }

  testWidgets('リスト: ふだんは ≡ を出さない。タップも長押しも選択で、動かしても並びは変わらない',
      (tester) async {
    final (c, toggled) = await pump(tester, TagViewMode.list);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    await tester.tap(find.text('い'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('う'));
    await tester.pumpAndSettle();
    expect(toggled, ['t1', 't2']);
    await holdAndDrag(tester, tester.getCenter(find.text('あ')),
        tester.getCenter(find.text('う')) + const Offset(0, 20));
    expect(names(c), ['あ', 'い', 'う', 'え']);
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

  testWidgets('リスト: 並べ替えモードは ⋮ の場所に ≡。触れてすぐ動かせ、右端・上下の端も同じ',
      (tester) async {
    await pump(tester, TagViewMode.list);
    final menu = tester.getCenter(find.byIcon(Icons.more_vert).first);
    final (c, toggled) = await pump(tester, TagViewMode.list, reordering: true);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    final handles = find.byIcon(Icons.drag_handle);
    expect(tester.getCenter(handles.first), menu);

    // 長押しを待たずに動かせる
    // （持ち上げると ≡ の数え方が変わるので、位置は先に取っておく）
    final from = tester.getCenter(handles.at(0));
    final to = tester.getCenter(handles.at(2)) + const Offset(0, 20);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    await slide(tester, gesture, from, to);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(names(c), ['い', 'う', 'あ', 'え']);

    // 列の右端・上下の端を押して離しても、選択にもならず並びも変わらない
    final row = tester.getRect(
        find.ancestor(of: find.text('い'), matching: find.byType(ListTile)));
    for (final from in [
      Offset(row.right - 2, row.center.dy),
      Offset(row.right - 30, row.top + 2),
      Offset(row.right - 30, row.bottom - 2),
    ]) {
      final g = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.up();
      await tester.pumpAndSettle();
    }
    expect(names(c), ['い', 'う', 'あ', 'え']);
    expect(toggled, isEmpty);
  });

  testWidgets('リスト: 並べ替えモードは行の長押しでも持ち上がる。タップしても選択しない', (tester) async {
    final (c, toggled) = await pump(tester, TagViewMode.list, reordering: true);
    await tester.tap(find.text('い'));
    await tester.pumpAndSettle();
    await holdAndDrag(tester, tester.getCenter(find.text('あ')),
        tester.getCenter(find.text('う')) + const Offset(0, 20));
    expect(names(c), ['い', 'う', 'あ', 'え']);
    expect(toggled, isEmpty);
  });

  for (final mode in TagViewMode.values) {
    testWidgets('${mode.label}: 並べ替えモードに入っても名前の位置と大きさが変わらない', (tester) async {
      await pump(tester, mode);
      final before = [for (final n in ['あ', 'い']) tester.getRect(find.text(n))];
      await pump(tester, mode, reordering: true);
      await tester.pumpAndSettle();
      final after = [for (final n in ['あ', 'い']) tester.getRect(find.text(n))];
      expect(after, before);
    });
  }

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
