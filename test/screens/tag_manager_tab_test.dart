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
            onTagTap: (_) {},
            onLongPress: (t) => longPressed.add(t.id),
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

    testWidgets('${mode.label}: 動かさずに離すと長押し（並びは変えない）', (tester) async {
      final (c, longPressed) = await pump(tester, mode);
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('い')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(names(c), ['あ', 'い', 'う', 'え']);
      expect(longPressed, ['t1']);
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
