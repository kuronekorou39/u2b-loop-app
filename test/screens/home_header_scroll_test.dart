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

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 400);
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
    final hiddenTop = tester.getRect(find.byType(ListView)).top;
    expect(hiddenTop, lessThan(listTop - 100));

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
}
