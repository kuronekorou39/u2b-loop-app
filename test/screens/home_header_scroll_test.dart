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
import 'package:u2b_loop_app/screens/home/tag_filter_bar.dart';
import 'package:u2b_loop_app/screens/list_screen.dart';
import 'package:u2b_loop_app/widgets/glass_controls.dart';

/// ホームの見出し（ロゴ・タブ・検索）: 一覧を下へ送ると上へ抜けて隠れ、戻すと出る。
/// 指で動かしている間、一覧の中身は指と同じだけ動く（見出しの縮みで余分に動かない）
void main() {
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    Hive.registerAdapter(PlaylistAdapter());
    Hive.registerAdapter(TagAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    final items =
        await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
    await Hive.openBox<Playlist>(AppBoxes.playlistsName, bytes: Uint8List(0));
    await Hive.openBox<Tag>(AppBoxes.tagsName, bytes: Uint8List(0));
    await AppBoxes.settings
        .put(SettingsKeys.homeItemView, ItemViewMode.list.name);
    for (var i = 0; i < 40; i++) {
      await items.put('i$i',
          LoopItem(id: 'i$i', title: '曲$i', uri: '/x$i.mp4', sourceType: 'local'));
    }
  });
  tearDownAll(() => Hive.close());

  Future<void> pump(WidgetTester tester,
      {Size size = const Size(900, 400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ListScreen())));
    await tester.pumpAndSettle();
  }

  Rect searchRect(WidgetTester tester) =>
      tester.getRect(find.byType(GlassSearchField));

  testWidgets('下へ送ると見出しが隠れ、戻すと出る。中身は指と同じだけ動く', (tester) async {
    await pump(tester);
    final search = searchRect(tester);
    expect(search.top, greaterThan(0));
    final listTop = tester.getRect(find.byType(ListView)).top;
    expect(listTop, greaterThan(search.bottom));

    // 少しだけ動かす: 中身（曲名）は指と同じだけ上がる
    // 一覧の 2 行目あたりの曲名（並びは更新順なので見えているものから取る）
    final shown = find.descendant(
        of: find.byType(ListView), matching: find.textContaining('曲'));
    final title = find.text((tester.widget<Text>(shown.at(1))).data!);
    // 最初の一動きはドラッグの始まり（遊び）に使われるので、その後から測る
    final gesture = await tester.startGesture(const Offset(450, 300));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    final before = tester.getRect(title).top;
    final topBefore = tester.getRect(find.byType(ListView)).top;
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(tester.getRect(title).top, closeTo(before - 40, 1.5));
    // 見出しも同じだけ上へ抜けた
    expect(tester.getRect(find.byType(ListView)).top, closeTo(topBefore - 40, 1.5));

    // さらに送ると見出しは全部隠れる
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField).hitTestable(), findsNothing);
    // 一覧の上端は状態バーのすぐ下まで上がる（見出しの分だけ広がる）
    final hiddenTop = tester.getRect(find.byType(ListView)).top;
    expect(hiddenTop, lessThan(search.top));

    // 少し戻すと見出しが出てくる（途中で離せば寄せる）
    await tester.dragFrom(const Offset(450, 200), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byType(ListView)).top, closeTo(listTop, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('タブを移ると見出しは出る', (tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(450, 300), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('プレイリスト').hitTestable(), findsNothing);
    // 横にスワイプしてプレイリストタブへ
    await tester.flingFrom(const Offset(700, 300), const Offset(-500, 0), 2000);
    await tester.pumpAndSettle();
    expect(find.text('プレイリスト').hitTestable(), findsOneWidget);
  });

  testWidgets('横画面はタグの絞り込みもボタンにして見出しの 1 行に入れる', (tester) async {
    await AppBoxes.tags.put('t1', Tag(id: 't1', name: 'ロック'));
    addTearDown(() => AppBoxes.tags.delete('t1'));
    await pump(tester);
    expect(find.byType(SelectedTagBar), findsNothing);
    final button = tester.getRect(find.byType(TagFilterButton));
    expect(button.center.dy, closeTo(searchRect(tester).center.dy, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('縦画面は検索を隠しておき、見出しの検索ボタンで出す。どのタブも一覧の高さは同じ',
      (tester) async {
    await pump(tester, size: const Size(400, 800));
    expect(find.byType(GlassSearchField), findsNothing);
    // 曲タブ（初期）とプレイリストタブで一覧の上端が同じ
    final itemsTop = tester.getRect(find.byType(ListView).first).top;
    await tester.tap(find.text('プレイリスト'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('検索'), findsNothing, reason: '曲タブだけ');
    await tester.tap(find.text('曲'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ListView).first).top, itemsTop);

    // 一覧の先頭の曲（並びは更新順なので見えているものから取る）
    final first = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(ListView).first,
            matching: find.textContaining('曲')))
        .first
        .data!;
    await tester.tap(find.byTooltip('検索'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ない曲名');
    await tester.pumpAndSettle();
    expect(find.text(first), findsNothing);
    // 閉じると検索語は消える
    await tester.tap(find.byTooltip('検索を閉じる'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField), findsNothing);
    expect(find.text(first), findsWidgets);
  });

  testWidgets('検索を開いたまま条件なしで別のタブへ行くと、戻ったとき検索の行は閉じている。条件があれば残る',
      (tester) async {
    await pump(tester, size: const Size(400, 800));
    await tester.tap(find.byTooltip('検索'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField), findsOneWidget);

    // 検索語があるうちは、行って戻っても出たまま
    await tester.enterText(find.byType(TextField), '曲1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('プレイリスト'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField), findsOneWidget);

    // 条件を消してから行って戻ると閉じている
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('タグ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSearchField), findsNothing);
    expect(find.byTooltip('検索'), findsOneWidget);
  });
}
