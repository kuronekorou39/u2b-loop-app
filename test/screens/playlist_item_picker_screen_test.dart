import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/playlist_item_picker_screen.dart';
import 'package:u2b_loop_app/widgets/glass_surface.dart';

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
      final many = [for (var i = 1; i <= 30; i++) Tag(id: 't$i', name: 'タグ $i')];
      PlaylistTagsResult? result;
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
      // 外した曲が無ければ「戻す」は出さない
      expect(find.textContaining('を戻す'), findsNothing);

      await tester.scrollUntilVisible(find.text('タグ 30'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('タグ 30'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(result?.tagIds, ['t3', 't30']);
      expect(result?.restoreExcluded, isFalse);
    });

    testWidgets('外した曲があれば「戻す」を選べる', (tester) async {
      final result = await open<PlaylistTagsResult>(
          tester,
          (ctx) => showPlaylistTagsDialog(ctx,
              tags: [Tag(id: 't1', name: 'ロック')],
              selected: {'t1'},
              countOf: (_) => 5,
              excludedCount: 2));
      expect(result, isNull); // まだ閉じていない
      await tester.tap(find.text('外した 2 曲を戻す'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<CheckboxListTile>(find.widgetWithText(
                  CheckboxListTile, '外した 2 曲を戻す'))
              .value,
          isTrue);
    });

    testWidgets('タグが無ければその旨を出す', (tester) async {
      await open<PlaylistTagsResult>(
          tester,
          (ctx) => showPlaylistTagsDialog(ctx,
              tags: const [], selected: const {}, countOf: (_) => 0));
      expect(find.text('タグがありません'), findsOneWidget);
    });
  });
}
