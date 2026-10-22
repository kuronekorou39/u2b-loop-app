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

/// ホームの一覧（曲のリスト・曲名、プレイリストのリスト）: 複数選択に入っても
/// 名前の位置と大きさが変わらない（チェックを差し込まずサムネに重ねる）
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
  });
  tearDownAll(() => Hive.close());

  final items = [
    for (var i = 0; i < 2; i++)
      LoopItem(id: 'i$i', title: '曲$i', uri: '/x$i.mp4', sourceType: 'local'),
  ];

  Future<void> pumpBody(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: Scaffold(body: body)),
    ));
    await tester.pump();
  }

  for (final mode in [ItemViewMode.list, ItemViewMode.titles]) {
    testWidgets('曲の${mode.label}: 選択に入っても曲名が動かない', (tester) async {
      Widget view(bool selecting) => ItemCollectionView(
            items: items,
            tags: const [],
            viewMode: mode,
            selectedIds: const {'i0'},
            selecting: selecting,
            onOpen: (_) {},
            onLongPress: (_) {},
            onToggleSelect: (_) {},
            onDelete: (_) {},
            onRetry: (_) {},
          );
      await pumpBody(tester, view(false));
      final before = [for (final t in ['曲0', '曲1']) tester.getRect(find.text(t))];
      await pumpBody(tester, view(true));
      final after = [for (final t in ['曲0', '曲1']) tester.getRect(find.text(t))];
      expect(after, before);
    });
  }

  testWidgets('プレイリストのリスト: 選択に入っても名前が動かない', (tester) async {
    for (final (i, name) in ['朝', '夜'].indexed) {
      await AppBoxes.playlists
          .put('p$i', Playlist(id: 'p$i', name: name, itemIds: ['i0']));
    }
    await AppBoxes.loopItems.put('i0', items[0]);
    Widget view(bool selecting) => PlaylistTab(
          selecting: selecting,
          selectedIds: const {'p0'},
        );
    await pumpBody(tester, view(false));
    final before = [for (final t in ['朝', '夜']) tester.getRect(find.text(t))];
    await pumpBody(tester, view(true));
    final after = [for (final t in ['朝', '夜']) tester.getRect(find.text(t))];
    expect(after, before);
  });
}
