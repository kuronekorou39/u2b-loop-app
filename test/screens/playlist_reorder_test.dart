import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/screens/home/import_tag_dialog.dart';
import 'package:u2b_loop_app/screens/home/playlist_tab.dart';
import 'package:u2b_loop_app/screens/playlist_detail_screen.dart';
import 'package:u2b_loop_app/services/backup_service.dart';
import 'package:u2b_loop_app/widgets/item_thumbnail.dart';
import 'package:u2b_loop_app/widgets/playlist_cover.dart';

/// プレイリスト一覧の並び順（手で並べ替え）と、取り込みのときのタグの 3 択
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

  final t0 = DateTime(2026, 1, 1);

  setUp(() async {
    await AppBoxes.playlists.clear();
    // 作った順は あ → い → う → え（一覧は新しい順なので え, う, い, あ）
    var day = 0;
    for (final (id, name) in [('p0', 'あ'), ('p1', 'い'), ('p2', 'う'), ('p3', 'え')]) {
      await AppBoxes.playlists.put(
          id,
          Playlist(
              id: id, name: name, createdAt: t0.add(Duration(days: day++))));
    }
  });

  Future<ProviderContainer> pump(WidgetTester tester,
      {bool grid = false, bool reordering = false}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          home: Scaffold(
              body: PlaylistTab(grid: grid, reordering: reordering))),
    ));
    await tester.pump();
    return container;
  }

  List<String> names(ProviderContainer c) =>
      c.read(playlistsProvider).map((p) => p.name).toList();

  /// 少しずつ動かす（行が場所を譲るアニメーションを進めながら）
  Future<void> slide(
      WidgetTester tester, TestGesture gesture, Offset from, Offset to) async {
    for (var k = 1; k <= 10; k++) {
      await gesture.moveTo(Offset.lerp(from, to, k / 10)!);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('表紙は曲の束（板 2 枚 + 左下に曲数の札）。グリッドは正方形、リストは今までの大きさ',
      (tester) async {
    await AppBoxes.loopItems.put(
        'a', LoopItem(id: 'a', title: '曲', uri: 'u', sourceType: 'local'));
    addTearDown(() => AppBoxes.loopItems.delete('a'));
    final pl = AppBoxes.playlists.get('p0')!..itemIds = ['a'];
    await AppBoxes.playlists.put('p0', pl);

    // グリッド: サムネは正方形（曲のグリッドは横長）
    await pump(tester, grid: true);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistCover), findsNWidgets(4));
    final thumb = tester.getSize(find.byType(ItemThumbnail).first);
    expect(thumb.width, closeTo(thumb.height, 0.5));
    expect(find.widgetWithText(PlaylistCountBadge, '1'), findsOneWidget);
    expect(find.textContaining(' 曲'), findsNothing, reason: '曲数は札だけ');
    expect(tester.takeException(), isNull);

    // リスト: 板の分も含めて 56 の中。行の高さはタグの有無でそろう
    await pump(tester);
    await tester.pumpAndSettle();
    final cover = tester.getSize(find.byType(PlaylistCover).first);
    expect(cover.width, 56);
    expect(cover.height, closeTo(56, 0.5));
    expect(find.widgetWithText(PlaylistCountBadge, '1'), findsOneWidget);
    final rows = tester.widgetList<ListTile>(find.byType(ListTile));
    expect(rows.map((t) => t.minTileHeight).toSet().length, 1);
  });

  test('並び: 決めていなければ新しい順。並べ替えると番号が振られ、新しく作ったものは先頭に入る',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(names(c), ['え', 'う', 'い', 'あ']);
    c.read(playlistsProvider.notifier).reorder(0, 2);
    expect(names(c), ['う', 'い', 'え', 'あ']);
    expect(AppBoxes.playlists.get('p2')!.order, 0);
    expect(AppBoxes.playlists.get('p0')!.order, 3);

    await c
        .read(playlistsProvider.notifier)
        .add(Playlist(id: 'p9', name: '新', createdAt: t0));
    expect(names(c), ['新', 'う', 'い', 'え', 'あ']);

    // 開き直しても同じ並び
    final again = ProviderContainer();
    addTearDown(again.dispose);
    expect(names(again), ['新', 'う', 'い', 'え', 'あ']);
  });

  test('バックアップに並び順が入る', () {
    final pl = Playlist(id: 'x', name: 'x', order: 5);
    expect(
        BackupService.playlistFromJson(BackupService.playlistToJson(pl)).order,
        5);
    expect(
        BackupService.playlistFromJson({'id': 'y', 'name': 'y'}).order, isNull);
  });

  testWidgets('リスト: ふだんは ≡ を出さない。並べ替えモードは ⋮ の場所が ≡ で、触れてすぐ動かせる',
      (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNWidgets(4));
    final menu = tester.getCenter(find.byIcon(Icons.more_vert).first);
    final name = tester.getRect(find.text('え'));

    final c = await pump(tester, reordering: true);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    final handles = find.byIcon(Icons.drag_handle);
    expect(handles, findsNWidgets(4));
    // ≡ は ⋮ とまったく同じ場所。名前も動かない
    expect(tester.getCenter(handles.first), menu);
    expect(tester.getRect(find.text('え')), name);

    final from = tester.getCenter(handles.at(0));
    final to = tester.getCenter(handles.at(2)) + const Offset(0, 20);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    await slide(tester, gesture, from, to);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(names(c), ['う', 'い', 'え', 'あ']);

    // タップしても開かない
    await tester.tap(find.text('い'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailScreen), findsNothing);
  });

  testWidgets('並べ替えモードは長押しを待たずに持てる（リストの行・グリッドのカード）', (tester) async {
    for (final grid in [false, true]) {
      final c = await pump(tester, grid: grid, reordering: true);
      expect(names(c), ['え', 'う', 'い', 'あ']);
      final from = tester.getCenter(find.text('え'));
      final to = tester.getCenter(find.text('い')) + const Offset(0, 20);
      final gesture = await tester.startGesture(from);
      // 長押し（0.5 秒）よりずっと短い
      await tester.pump(const Duration(milliseconds: 150));
      await slide(tester, gesture, from, to);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(names(c), ['う', 'い', 'え', 'あ'], reason: 'grid=$grid');
      c.read(playlistsProvider.notifier).reorder(2, 0);
    }
  });

  testWidgets('グリッド: 並べ替えモードは長押しで動かす。ふだんは動かない', (tester) async {
    Future<void> holdAndDrag(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await slide(tester, gesture, from, to);
      await gesture.up();
      await tester.pumpAndSettle();
    }

    var c = await pump(tester, grid: true);
    await holdAndDrag(
        tester.getCenter(find.text('え')), tester.getCenter(find.text('い')));
    expect(names(c), ['え', 'う', 'い', 'あ']);

    c = await pump(tester, grid: true, reordering: true);
    await holdAndDrag(
        tester.getCenter(find.text('え')), tester.getCenter(find.text('い')));
    expect(names(c), ['う', 'い', 'え', 'あ']);
    await tester.tap(find.text('う'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailScreen), findsNothing);
  });

  group('取り込みのタグ', () {
    final tags = [
      for (var i = 0; i < 30; i++) Tag(id: 't$i', name: 'タグ$i', order: i),
    ];

    Future<List<Object?>> open(WidgetTester tester, List<Tag> tags,
        {String name = '新しい名前'}) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final results = <Object?>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(await showImportTagDialog(
                context,
                tags: tags,
                newTagName: name,
                createTag: (n) async => Tag(id: 'new', name: n))),
            child: const Text('開く'),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('最初は 3 択だけ（タグは並べない）。作って付ける / 付けない', (tester) async {
      final results = await open(tester, tags);
      expect(find.text('タグ0'), findsNothing);
      expect(find.byType(ListTile), findsNWidgets(3));
      await tester.tap(find.text('「新しい名前」を作って付ける'));
      await tester.pumpAndSettle();
      expect(results, ['new']);

      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('付けない'));
      await tester.pumpAndSettle();
      expect(results, ['new', null]);
    });

    testWidgets('今あるタグから選ぶ: 一覧は次のダイアログ。戻ると 3 択に戻る', (tester) async {
      final results = await open(tester, tags);
      await tester.tap(find.text('今あるタグから選ぶ'));
      await tester.pumpAndSettle();
      expect(find.text('タグ0'), findsOneWidget);
      await tester.tap(find.text('戻る'));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text('付けない'), findsOneWidget);

      await tester.tap(find.text('今あるタグから選ぶ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('タグ2'));
      await tester.pumpAndSettle();
      expect(results, ['t2']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('同じ名前のタグがあれば作らずにそれを付ける。タグが無ければ「選ぶ」は出さない',
        (tester) async {
      var results = await open(tester, tags, name: 'タグ3');
      expect(find.text('「タグ3」を作って付ける'), findsNothing);
      await tester.tap(find.text('「タグ3」を付ける'));
      await tester.pumpAndSettle();
      expect(results, ['t3']);

      results = await open(tester, const []);
      expect(find.text('今あるタグから選ぶ'), findsNothing);
      expect(find.byType(ListTile), findsNWidgets(2));
    });
  });
}
