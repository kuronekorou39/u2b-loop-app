import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/loop_state.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/detail_screen.dart';
import 'package:u2b_loop_app/screens/home/item_views.dart';
import 'package:u2b_loop_app/screens/home/playlist_tab.dart';
import 'package:u2b_loop_app/screens/playlist_detail_screen.dart';
import 'package:u2b_loop_app/widgets/loop/region_panel.dart';
import 'package:u2b_loop_app/widgets/player/fullscreen_player_view.dart';

/// 一覧の行の ⋮ から出るメニューは、下のシートではなくその行のすぐ上か下に出す
/// （行は明るいまま。どの行のメニューかが見て分かる）。
/// 画面ごとに、メニューが行の脇に出ること・行の部品が「行の context」を渡すことを確かめる
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

  final regions = [
    LoopRegion(id: 'r1', name: 'サビ', pointAMs: 1000, pointBMs: 5000),
    LoopRegion(id: 'r2', name: '間奏', pointAMs: 8000, pointBMs: 9000),
  ];

  setUp(() async {
    await AppBoxes.loopItems.clear();
    await AppBoxes.playlists.clear();
    for (final id in ['a', 'b', 'c']) {
      await AppBoxes.loopItems.put(
          id,
          LoopItem(
              id: id,
              title: '曲 $id',
              uri: 'u',
              sourceType: 'local',
              regions: id == 'a' ? regions : null));
    }
    await AppBoxes.playlists
        .put('p', Playlist(id: 'p', name: 'リスト', itemIds: ['a', 'b', 'c']));
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: home)));
    await tester.pumpAndSettle();
  }

  Rect rectOf(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 項目 [label] を含むメニューの面が、行 [row] のすぐ下か上にある（下のシートではない）
  void expectBesideRow(WidgetTester tester, Rect row, String label) {
    expect(find.byType(BottomSheet), findsNothing, reason: '下のシートではない');
    final menu = tester.getRect(find
        .ancestor(of: find.text(label), matching: find.byType(Material))
        .first);
    final below = (menu.top - row.bottom).abs() < 10;
    final above = (row.top - menu.bottom).abs() < 10;
    expect(below || above, isTrue, reason: 'メニュー $menu / 行 $row');
  }

  Rect tileOf(WidgetTester tester, String text) => tester.getRect(
      find.ancestor(of: find.text(text), matching: find.byType(ListTile)).first);

  testWidgets('プレイリストの一覧: 行の ⋮', (tester) async {
    await pump(tester, const Scaffold(body: PlaylistTab()));
    await tester.tap(find.byTooltip('メニュー').first);
    await tester.pumpAndSettle();
    expectBesideRow(tester, tileOf(tester, 'リスト'), '複製');
  });

  testWidgets('プレイリスト詳細: 曲の行の ⋮', (tester) async {
    await pump(tester, const PlaylistDetailScreen(playlistId: 'p'));
    final row = tileOf(tester, '曲 b');
    await tester.tap(find.byTooltip('メニュー').at(1));
    await tester.pumpAndSettle();
    expectBesideRow(tester, row, 'プレイリストから外す');
  });

  testWidgets('曲の詳細: AB 区間の行のタップ', (tester) async {
    await pump(tester, const DetailScreen(itemId: 'a'));
    await tester.ensureVisible(find.text('間奏'));
    await tester.pumpAndSettle();
    final row = tester.getRect(
        find.ancestor(of: find.text('間奏'), matching: find.byType(InkWell)).first);
    await tester.tap(find.text('間奏'));
    await tester.pumpAndSettle();
    expectBesideRow(tester, row, '名前を変更');
  });

  group('行の部品は、行の context を渡す', () {
    testWidgets('曲の一覧（リスト）: ⋮ と、取得に失敗した曲のタップ', (tester) async {
      final menus = <(String, Rect)>[], opens = <(String, Rect)>[];
      final items = [
        LoopItem(id: 'a', title: '曲 a', uri: 'u', sourceType: 'local'),
        LoopItem(
            id: 'e',
            title: '失敗',
            uri: 'u',
            sourceType: 'youtube',
            fetchStatus: 'error'),
      ];
      await pump(
        tester,
        Scaffold(
          body: ItemCollectionView(
            items: items,
            tags: const [],
            viewMode: ItemViewMode.titles,
            selectedIds: const {},
            selecting: false,
            onOpen: (item, anchor) => opens.add((item.id, rectOf(anchor))),
            onLongPress: (_) {},
            onToggleSelect: (_) {},
            onMenu: (item, anchor) => menus.add((item.id, rectOf(anchor))),
          ),
        ),
      );
      await tester.tap(find.byTooltip('メニュー').at(1));
      await tester.tap(find.text('曲 a'));
      expect(menus.single, ('e', tileOf(tester, '失敗')));
      expect(opens.single, ('a', tileOf(tester, '曲 a')));
    });

    testWidgets('曲の一覧（グリッド）: カードのタップはカードを渡す', (tester) async {
      Rect? anchor;
      await pump(
        tester,
        Scaffold(
          body: ItemCollectionView(
            items: AppBoxes.loopItems.values.toList(),
            tags: const [],
            viewMode: ItemViewMode.grid2,
            selectedIds: const {},
            selecting: false,
            onOpen: (_, a) => anchor = rectOf(a),
            onLongPress: (_) {},
            onToggleSelect: (_) {},
            onMenu: (_, _) {},
          ),
        ),
      );
      final title = tester.getRect(find.text('曲 b'));
      await tester.tap(find.text('曲 b'));
      // カード 1 枚（一覧全体ではない）
      expect(anchor!.contains(title.center), isTrue);
      expect(anchor!.width, lessThan(tester.view.physicalSize.width / 3 * 0.7));
    });

    testWidgets('単体再生の区間パネル: ⋮', (tester) async {
      final anchors = <int, Rect>{};
      await pump(
        tester,
        Scaffold(
          body: RegionPanel(
            regions: regions,
            selectedIndex: 0,
            onSelect: (_) {},
            onMenu: (i, a) => anchors[i] = rectOf(a),
            onAdd: null,
          ),
        ),
      );
      await tester.tap(find.byTooltip('リネーム・削除').at(1));
      final name = tester.getRect(find.text('間奏'));
      expect(anchors.keys, [1]);
      expect(anchors[1]!.contains(name.center), isTrue);
      expect(anchors[1]!.height, lessThan(80), reason: '1 行（パネル全体ではない）');
    });

    testWidgets('全画面の区間のドロワー: ⋮', (tester) async {
      final anchors = <int, Rect>{};
      await pump(
        tester,
        Scaffold(
          body: FullscreenRegionDrawer(
            regions: regions,
            activeIndex: 0,
            loop: const LoopState(enabled: true),
            bottomInset: 0,
            onToggleLoop: null,
            onExport: ({required fullTrack}) {},
            onSelectAll: () {},
            onSelect: (_) {},
            onMenu: (i, a) => anchors[i] = rectOf(a),
          ),
        ),
      );
      final name = tester.getRect(find.text('間奏'));
      await tester.tap(find.byTooltip('メニュー').at(1));
      expect(anchors.keys, [1]);
      expect(anchors[1]!.contains(name.center), isTrue);
      expect(anchors[1]!.height, lessThan(80), reason: '1 行（一覧全体ではない）');
    });
  });
}
