import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/playlist_item_picker_screen.dart';
import 'package:u2b_loop_app/widgets/glass_surface.dart';
import 'package:u2b_loop_app/widgets/item_thumbnail.dart';

/// プレイリストの「曲を追加」: 一覧から選択の画面と、入口・タグのダイアログ。
/// 以前はタグのシートが Column 直書きでスクロールできなかったので、
/// 件数が多いときに最後まで流れることを確かめる
void main() {
  LoopItem item(int n, {List<String>? tagIds, List<LoopRegion>? regions}) =>
      LoopItem(
        id: 'i$n',
        title: '曲 $n',
        uri: 'u',
        sourceType: 'local',
        tagIds: tagIds,
        regions: regions,
      );

  final tags = [
    Tag(id: 't1', name: '練習'),
    Tag(id: 't2', name: '本番', colorIndex: 1),
  ];

  /// 一覧のスクロール（タグのチップの横スクロールと区別する）
  final listScrollable = find.descendant(
      of: find.byType(GlassSurface), matching: find.byType(Scrollable));

  Future<({List<List<String>> ids, List<Map<String, List<String>>> regions})>
      pump(WidgetTester tester, List<LoopItem> items,
          {Set<String> existing = const {}}) async {
    final ids = <List<String>>[], regions = <Map<String, List<String>>>[];
    await tester.pumpWidget(MaterialApp(
      home: PlaylistItemPickerScreen(
        items: items,
        tags: tags,
        existingIds: existing,
        onAdd: (i, r) {
          ids.add(i);
          regions.add(r);
        },
      ),
    ));
    return (ids: ids, regions: regions);
  }

  testWidgets('件数の多い一覧が最後までスクロールできる', (tester) async {
    await pump(tester, [for (var i = 1; i <= 40; i++) item(i)]);
    expect(find.text('曲 40'), findsNothing);
    await tester.scrollUntilVisible(find.text('曲 40'), 300,
        scrollable: listScrollable);
    expect(find.text('曲 40'), findsOneWidget);
  });

  testWidgets('行のタップで選び、右上の「追加 (n)」で ID が渡る', (tester) async {
    final r = await pump(tester, [item(1), item(2), item(3)],
        existing: {'i3'});
    expect(find.text('追加 (0)'), findsOneWidget);
    expect(find.text('追加済み'), findsOneWidget);

    await tester.tap(find.text('曲 1'));
    await tester.pump();
    await tester.tap(find.text('曲 2'));
    await tester.pump();
    expect(find.text('追加 (2)'), findsOneWidget);

    // 追加済みの行は選べない
    await tester.tap(find.text('曲 3'));
    await tester.pump();
    expect(find.text('追加 (2)'), findsOneWidget);

    await tester.tap(find.text('追加 (2)'));
    await tester.pumpAndSettle();
    expect(r.ids, [
      ['i1', 'i2']
    ]);
    expect(r.regions, [<String, List<String>>{}]);
  });

  testWidgets('検索とタグのチップで絞り込める', (tester) async {
    await pump(tester, [
      item(1, tagIds: ['t1']),
      item(2, tagIds: ['t2']),
      item(3, tagIds: ['t1', 't2']),
    ]);
    await tester.tap(find.text('本番'));
    await tester.pump();
    expect(find.text('曲 1'), findsNothing);
    expect(find.text('曲 2'), findsOneWidget);
    expect(find.text('曲 3'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '3');
    await tester.pump();
    expect(find.text('曲 2'), findsNothing);
    expect(find.text('曲 3'), findsOneWidget);

    // もう一度タップで絞り込みを外す
    await tester.tap(find.text('本番'));
    await tester.enterText(find.byType(TextField), 'ない');
    await tester.pump();
    expect(find.text('該当する曲がありません'), findsOneWidget);
  });

  testWidgets('タグの絞り込みは OR（選んだタグのどれかが付いた曲）', (tester) async {
    await pump(tester, [
      item(1, tagIds: ['t1']),
      item(2, tagIds: ['t2']),
      item(3, tagIds: ['t1', 't2']),
      item(4),
    ]);
    await tester.tap(find.text('練習'));
    await tester.pump();
    await tester.tap(find.text('本番'));
    await tester.pump();
    for (final n in [1, 2, 3]) {
      expect(find.text('曲 $n'), findsOneWidget, reason: '$n');
    }
    expect(find.text('曲 4'), findsNothing);
  });

  testWidgets('表示中の曲をまとめて選べ、もう一度押すと外れる（入っている曲は除く）', (tester) async {
    await pump(tester, [
      item(1, tagIds: ['t1']),
      item(2, tagIds: ['t1']),
      item(3, tagIds: ['t1']),
      item(4),
    ], existing: {'i3'});
    await tester.tap(find.text('練習'));
    await tester.pump();
    await tester.tap(find.byTooltip('全選択'));
    await tester.pump();
    expect(find.text('追加 (2)'), findsOneWidget);
    // 絞り込みの外の曲は選ばない
    await tester.tap(find.text('練習'));
    await tester.pump();
    expect(find.byTooltip('全選択'), findsOneWidget);
    await tester.tap(find.text('練習'));
    await tester.pump();
    await tester.tap(find.byTooltip('全解除'));
    await tester.pump();
    expect(find.text('追加 (0)'), findsOneWidget);
  });

  testWidgets('区間のある曲をまとめて選ぶと全区間が入る（行は開かない）', (tester) async {
    final r = await pump(tester, [
      item(1, regions: [
        LoopRegion(id: 'r1', name: 'サビ', pointAMs: 1000, pointBMs: 5000),
        LoopRegion(id: 'r2', name: 'ソロ', pointAMs: 6000, pointBMs: 9000),
      ]),
      item(2),
    ]);
    await tester.tap(find.byTooltip('全選択'));
    await tester.pump();
    expect(find.text('サビ'), findsNothing);
    await tester.tap(find.text('追加 (2)'));
    await tester.pumpAndSettle();
    expect(r.ids.single, ['i1', 'i2']);
    expect(r.regions.single['i1'], unorderedEquals(['r1', 'r2']));
  });

  testWidgets('横画面は左右と下の画面の端（ナビゲーションバー・ジェスチャーの帯）を避ける',
      (tester) async {
    tester.view.physicalSize = const Size(923, 411);
    tester.view.devicePixelRatio = 1;
    const pad = FakeViewPadding(top: 24, left: 30, right: 48, bottom: 20);
    tester.view.padding = pad;
    tester.view.viewPadding = pad;
    addTearDown(tester.view.reset);
    await pump(tester, [item(1), item(2)]);
    final list = tester.getRect(listScrollable);
    expect(list.left, greaterThanOrEqualTo(30));
    expect(list.right, lessThanOrEqualTo(923 - 48));
    expect(list.bottom, lessThanOrEqualTo(411 - 20));
    final search = tester.getRect(find.byType(TextField));
    expect(search.left, greaterThanOrEqualTo(30));
    expect(search.right, lessThanOrEqualTo(923 - 48));
    expect(tester.getRect(find.text('練習')).left, greaterThanOrEqualTo(30));
    expect(tester.getRect(find.text('追加 (0)')).right, lessThanOrEqualTo(923 - 48));
  });

  testWidgets('区間のある曲は開いて区間ごとに選べ、全部外すと曲も外れる', (tester) async {
    final regions = [
      LoopRegion(id: 'r1', name: 'サビ', pointAMs: 1000, pointBMs: 5000),
      LoopRegion(id: 'r2', name: 'ソロ'),
    ];
    final r = await pump(tester, [item(1, regions: regions)]);
    expect(find.text('3 区間（全体含む）'), findsOneWidget);
    expect(find.text('サビ'), findsNothing);

    // 選ぶと全区間が選ばれて開く
    await tester.tap(find.text('曲 1'));
    await tester.pump();
    expect(find.text('サビ'), findsOneWidget);
    expect(find.text('全体'), findsOneWidget);
    expect(find.text('0:01 - 0:05'), findsOneWidget);
    expect(find.text('追加 (1)'), findsOneWidget);

    // 「全体」も足し、ソロを外す
    await tester.tap(find.text('全体'));
    await tester.tap(find.text('ソロ'));
    await tester.pump();
    await tester.tap(find.text('追加 (1)'));
    await tester.pumpAndSettle();
    expect(r.ids, [
      ['i1']
    ]);
    expect(r.regions.single['i1'], unorderedEquals(['r1', '__full__']));
  });

  testWidgets('区間を全部外すと曲の選択も外れる', (tester) async {
    final regions = [LoopRegion(id: 'r1', name: 'サビ')];
    await pump(tester, [item(1, regions: regions)]);
    await tester.tap(find.text('曲 1'));
    await tester.pump();
    await tester.tap(find.text('サビ'));
    await tester.pump();
    expect(find.text('追加 (0)'), findsOneWidget);
    expect(find.text('サビ'), findsNothing);
  });

  group('ダイアログ', () {
    Future<T?> open<T>(
        WidgetTester tester, Future<T?> Function(BuildContext) show) async {
      T? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => result = await show(ctx),
            child: const Text('開く'),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('入口のダイアログは中央に出て、選んだ入口を返す', (tester) async {
      PlaylistAddChoice? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => result = await showPlaylistAddDialog(ctx),
            child: const Text('開く'),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('タグで自動追加'));
      await tester.pumpAndSettle();
      expect(result, PlaylistAddChoice.byTag);
    });

    testWidgets('タグのダイアログは複数選べ、件数が多くてもスクロールできる。結果はタグ一覧の並び',
        (tester) async {
      // 縦の電話（既定の 800x600 は横向きなので 2 列になる）
      tester.view.physicalSize = const Size(411, 923);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final many = [for (var i = 1; i <= 30; i++) Tag(id: 't$i', name: 'タグ $i')];
      List<String>? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => result = await showPlaylistTagsDialog(
              ctx,
              tags: many,
              selected: {'t3'},
              countOf: (_) => 2,
            ),
            child: const Text('開く'),
          ),
        ),
      ));
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      expect(find.text('タグ 30'), findsNothing);
      // 選んであるタグは先頭に、名前と同じ行の右に曲数
      expect(tester.getTopLeft(find.text('タグ 3')).dy,
          lessThan(tester.getTopLeft(find.text('タグ 1')).dy));
      expect(tester.getCenter(find.text('2 曲').first).dy,
          closeTo(tester.getCenter(find.text('タグ 3')).dy, 1));
      expect(tester.getTopLeft(find.text('2 曲').first).dx,
          greaterThan(tester.getTopRight(find.text('タグ 3')).dx));
      // 選んだタグとほかのタグの間に区切りの線
      final line = tester.getRect(find.byType(Divider)).top;
      expect(tester.getTopLeft(find.text('タグ 3')).dy, lessThan(line));
      expect(tester.getTopLeft(find.text('タグ 1')).dy, greaterThan(line));
      // オンにすると選んだタグの側へ（タグ一覧の並びで タグ 3 の下）、オフで戻る
      await tester.tap(find.text('タグ 5'));
      await tester.pumpAndSettle();
      final picked = tester.getTopLeft(find.text('タグ 5')).dy;
      expect(picked, greaterThan(tester.getTopLeft(find.text('タグ 3')).dy));
      expect(picked, lessThan(tester.getRect(find.byType(Divider)).top));
      await tester.tap(find.text('タグ 5'));
      await tester.pumpAndSettle();
      final back = tester.getTopLeft(find.text('タグ 5')).dy;
      expect(back, greaterThan(tester.getTopLeft(find.text('タグ 4')).dy));
      expect(back, greaterThan(tester.getRect(find.byType(Divider)).top));

      await tester.scrollUntilVisible(find.text('タグ 30'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('タグ 30'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(result, ['t3', 't30']);
    });

    testWidgets('タグのダイアログ: 横画面は左に選んだタグ、右にほかのタグ。サムネも出す', (tester) async {
      tester.view.physicalSize = const Size(923, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final some = [for (var i = 1; i <= 4; i++) Tag(id: 't$i', name: 'タグ $i')];
      final thumbs = {
        't2': LoopItem(
            id: 'a', title: 'a', uri: 'u', sourceType: 'local', thumbnailPath: '/none.png'),
      };
      await open<List<String>>(
          tester,
          (ctx) => showPlaylistTagsDialog(ctx,
              tags: some,
              selected: {'t2'},
              countOf: (_) => 1,
              thumbOf: (t) => thumbs[t.id]));
      final picked = tester.getRect(find.text('タグ 2'));
      final other = tester.getRect(find.text('タグ 1'));
      expect(other.left, greaterThan(picked.right), reason: '右の列');
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byType(Divider), findsNothing);
      // 選ぶと左の列へ移る
      await tester.tap(find.text('タグ 3'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('タグ 3')).left, closeTo(picked.left, 1));
      // サムネ（無いタグは色の面）
      expect(find.byType(ItemThumbnail), findsOneWidget);
    });

    testWidgets('タグが無ければその旨を出す', (tester) async {
      await open<List<String>>(
          tester,
          (ctx) => showPlaylistTagsDialog(ctx,
              tags: const [], selected: const {}, countOf: (_) => 0));
      expect(find.text('タグがありません'), findsOneWidget);
    });
  });
}
