import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/home/item_views.dart';
import 'package:u2b_loop_app/screens/home/playlist_tab.dart';
import 'package:u2b_loop_app/screens/home/tag_manager_tab.dart';
import 'package:u2b_loop_app/screens/playlist_detail_screen.dart';

/// 一覧の長押しは、行・カードの中のボタン（⋮・再生）の上でも選択になる
/// （ボタンの吹き出しが長押しを取って、ボタンの所だけ選択に入らなかった）
void main() {
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    Hive.registerAdapter(PlaylistAdapter());
    Hive.registerAdapter(TagAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
    await Hive.openBox<Playlist>(AppBoxes.playlistsName, bytes: Uint8List(0));
    await Hive.openBox<Tag>(AppBoxes.tagsName, bytes: Uint8List(0));
    await AppBoxes.settings.put(SettingsKeys.tagOrderHintSeen, true);
    for (final id in ['a', 'b']) {
      await AppBoxes.loopItems
          .put(id, LoopItem(id: id, title: '曲 $id', uri: 'u', sourceType: 'local'));
    }
    await AppBoxes.playlists.put('p', Playlist(id: 'p', name: 'リスト', itemIds: ['a', 'b']));
    await AppBoxes.tags.put('t', Tag(id: 't', name: 'ロック'));
  });
  tearDownAll(() => Hive.close());

  Future<void> pump(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: Scaffold(body: body)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('曲の一覧: ⋮ の上の長押しも選択', (tester) async {
    final pressed = <String>[];
    final items = AppBoxes.loopItems.values.toList();
    await pump(
      tester,
      ItemCollectionView(
        items: items,
        tags: const [],
        viewMode: ItemViewMode.titles,
        selectedIds: const {},
        selecting: false,
        onOpen: (_) {},
        onLongPress: (i) => pressed.add(i.id),
        onToggleSelect: (_) {},
        onDelete: (_) {},
        onRetry: (_) {},
      ),
    );
    await tester.longPress(find.byTooltip('メニュー').first);
    await tester.pumpAndSettle();
    expect(pressed, hasLength(1));
  });

  for (final grid in [false, true]) {
    testWidgets('プレイリストの一覧（${grid ? 'グリッド' : 'リスト'}）: 再生ボタンの上の長押しも選択',
        (tester) async {
      final pressed = <String>[];
      await pump(
          tester,
          PlaylistTab(
            grid: grid,
            onLongPress: (p) => pressed.add(p.id),
          ));
      final play = grid ? find.byTooltip('再生') : find.text('再生');
      await tester.longPress(play.first);
      await tester.pumpAndSettle();
      expect(pressed, ['p']);
      if (!grid) {
        await tester.longPress(find.byTooltip('メニュー').first);
        await tester.pumpAndSettle();
        expect(pressed, ['p', 'p']);
      }
    });
  }

  testWidgets('タグの一覧: ⋮ の上の長押しも選択', (tester) async {
    final toggled = <String>[];
    await pump(
      tester,
      TagManagerTab(
        viewMode: TagViewMode.list,
        onToggleSelect: (t) => toggled.add(t.id),
      ),
    );
    await tester.longPress(find.byTooltip('メニュー').first);
    await tester.pumpAndSettle();
    expect(toggled, ['t']);
  });

  testWidgets('プレイリスト詳細: 曲の行の ⋮ の上の長押しも選択', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: PlaylistDetailScreen(playlistId: 'p')),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.byTooltip('メニュー').first);
    await tester.pumpAndSettle();
    expect(find.text('1 曲を選択'), findsOneWidget);
  });
}
