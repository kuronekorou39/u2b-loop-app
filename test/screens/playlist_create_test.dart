import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/constants.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/screens/home/item_views.dart';
import 'package:u2b_loop_app/screens/home/playlist_tab.dart';
import 'package:u2b_loop_app/widgets/tag_chip.dart';
import 'package:u2b_loop_app/widgets/playlist_cover.dart';

/// プレイリストの作成（空 / タグから）・一覧のタグ表示・名前の長さ、曲のリスト大 / 小
void main() {
  final longName = 'とても長い名前' * 12;

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

  setUp(() async {
    await AppBoxes.playlists.clear();
    await AppBoxes.tags.clear();
    await AppBoxes.loopItems.clear();
    await AppBoxes.tags.put('r', Tag(id: 'r', name: 'ロック', order: 0));
    await AppBoxes.tags.put('j', Tag(id: 'j', name: 'ジャズ', order: 1));
    await AppBoxes.loopItems.put(
        'a',
        LoopItem(
            id: 'a',
            title: '曲A',
            uri: '/a.mp4',
            sourceType: 'local',
            memo: 'メモA',
            tagIds: ['r']));
    await AppBoxes.loopItems.put('b',
        LoopItem(id: 'b', title: '曲B', uri: '/b.mp4', sourceType: 'local'));
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget body,
      {Size size = const Size(400, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: body)),
    ));
    await tester.pump();
    return container;
  }

  Widget createButton() => Consumer(
        builder: (context, ref, _) => Column(
          children: [
            TextButton(
              onPressed: () => PlaylistTab.createPlaylist(context, ref),
              child: const Text('作る'),
            ),
            const Expanded(child: PlaylistTab()),
          ],
        ),
      );

  test('名前の切り詰め: 上限まで。絵文字の途中では切らない', () {
    expect(AppLimits.clip('  abc  ', 10), 'abc');
    expect(AppLimits.clip('abcdef', 3), 'abc');
    expect(AppLimits.clip('ab😀cd', 3), 'ab');
  });

  testWidgets('入力欄を通らずに作るタグも名前は上限まで', (tester) async {
    final c = await pump(tester, const SizedBox());
    final tag = await c.read(tagsProvider.notifier).create(longName);
    expect(tag.name.length, AppLimits.tagNameMaxLength);
  });

  testWidgets('空で作る: 名前を聞かずにすぐ作る', (tester) async {
    final c = await pump(tester, createButton());
    await tester.tap(find.text('作る'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空で作る'));
    await tester.pumpAndSettle();
    final pl = c.read(playlistsProvider).single;
    expect(pl.name, PlaylistTab.newPlaylistName);
    expect(pl.itemIds, isEmpty);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('タグから作る: 選んだタグの曲が入り、一覧にタグが出る。あとからタグを付けた曲も入る',
      (tester) async {
    final c = await pump(tester, createButton());
    await tester.tap(find.text('作る'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('タグから作る'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ロック'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    var pl = c.read(playlistsProvider).single;
    expect(pl.name, 'ロック');
    expect(pl.tagIds, ['r']);
    expect(pl.itemIds, ['a']);
    expect(find.widgetWithText(TagChip, 'ロック'), findsOneWidget);

    await c.read(loopItemsProvider.notifier).addTagToItems(['b'], 'r');
    await tester.pumpAndSettle();
    pl = c.read(playlistsProvider).single;
    expect(pl.itemIds, ['a', 'b']);
    // 曲数は表紙の札
    expect(find.widgetWithText(PlaylistCountBadge, '2'), findsOneWidget);
  });

  for (final grid in [false, true]) {
    testWidgets('一覧（${grid ? 'グリッド' : 'リスト'}）: 長い名前・長いタグ名でもはみ出さない',
        (tester) async {
      await AppBoxes.tags.put('l', Tag(id: 'l', name: longName, order: 2));
      await AppBoxes.playlists.put(
          'p',
          Playlist(
              id: 'p', name: longName, itemIds: ['a'], tagIds: ['l', 'r']));
      await pump(tester, PlaylistTab(grid: grid), size: const Size(360, 700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final name = tester.getSize(find.text(longName).first);
      expect(name.height, lessThan(60));
      final chip = tester.getSize(find.byType(TagChip).first);
      expect(chip.width, lessThanOrEqualTo(TagChip.maxWidth));
    });
  }

  testWidgets('曲のリスト小は曲名だけ、リスト大は情報とタグも出す', (tester) async {
    Widget view(ItemViewMode mode) => ItemCollectionView(
          items: AppBoxes.loopItems.values.toList(),
          tags: AppBoxes.tags.values.toList(),
          viewMode: mode,
          selectedIds: const {},
          selecting: false,
          onOpen: (_, _) {},
          onLongPress: (_) {},
          onToggleSelect: (_) {},
          onMenu: (_, _) {},
        );
    expect(ItemViewMode.list.label, 'リスト小');
    expect(ItemViewMode.titles.label, 'リスト大');

    await pump(tester, view(ItemViewMode.list));
    expect(find.text('曲A'), findsOneWidget);
    expect(find.textContaining('メモA'), findsNothing);
    expect(find.byType(TagChip), findsNothing);

    await pump(tester, view(ItemViewMode.titles));
    expect(find.textContaining('メモA'), findsOneWidget);
    expect(find.byType(TagChip), findsOneWidget);
  });
}
