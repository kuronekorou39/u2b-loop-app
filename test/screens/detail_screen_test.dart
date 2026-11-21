import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/detail_screen.dart';
import 'package:u2b_loop_app/widgets/glass_surface.dart';
import 'package:u2b_loop_app/widgets/item_thumbnail.dart';

/// 曲の詳細: AB 区間は再生画面で登録する（ここに「AB 設定」「＋設定」は無い）。
/// テンポ / キーとつなぎやすい曲は値だけを 1 行に並べ、タグ → AB 区間 → メモ（控えめ）の順
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

  Future<void> pump(WidgetTester tester, LoopItem item) async {
    await AppBoxes.loopItems.clear();
    await AppBoxes.loopItems.put(item.id, item);
    tester.view.physicalSize = const Size(1080, 2700);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: DetailScreen(itemId: item.id)),
    ));
    await tester.pumpAndSettle();
  }

  LoopItem analyzed() => LoopItem(
        id: 'a',
        title: '曲',
        uri: 'u',
        sourceType: 'local',
      )
        ..bpm = 128
        ..musicalKey = 'Amin'
        ..analyzedAt = 1
        ..regions = [
          LoopRegion(id: 'r', name: 'サビ', pointAMs: 60000, pointBMs: 90000),
        ];

  testWidgets('AB 区間を設定する入口は無い（登録は再生画面で）', (tester) async {
    await pump(tester, analyzed());
    expect(find.text('AB 設定'), findsNothing);
    expect(find.text('設定'), findsNothing);
    expect(find.text('編集'), findsNothing);
    // 登録済みの区間は一覧に出る
    expect(find.text('AB 区間'), findsOneWidget);
    expect(find.text('サビ'), findsOneWidget);
  });

  testWidgets('テンポ / キーとつなぎやすい曲は値だけを 1 行に。説明文は出さない', (tester) async {
    await pump(tester, analyzed());
    final value = tester.getRect(find.text('128 BPM · Amin (8A)'));
    final similar = tester.getRect(find.text('つなぎやすい曲'));
    expect((value.center.dy - similar.center.dy).abs(), lessThan(4));
    expect(similar.left, greaterThan(value.right));
    expect(find.text('テンポ / キー'), findsNothing);
    expect(find.textContaining('タップで'), findsNothing);
    expect(find.textContaining('ライブラリから探す'), findsNothing);
  });

  testWidgets('並びはテンポ / キー → タグ → AB 区間 → メモ。メモは面を敷かず控えめに',
      (tester) async {
    await pump(tester, analyzed());
    final tempo = tester.getRect(find.text('128 BPM · Amin (8A)')).top;
    final tags = tester.getRect(find.text('タグ')).top;
    final regions = tester.getRect(find.text('AB 区間')).top;
    final memo = tester.getRect(find.text('メモ')).top;
    expect(tempo, lessThan(tags));
    expect(tags, lessThan(regions));
    expect(regions, lessThan(memo));
    expect(
        find.ancestor(of: find.text('メモ'), matching: find.byType(GlassSurface)),
        findsNothing);
    // 小さい字（見出しの大きさにしない）
    final style = tester.widget<Text>(find.text('メモ')).style!;
    expect(style.fontSize, lessThanOrEqualTo(12));
  });

  testWidgets('横画面: 左の列はサムネを大きく、すぐ下に再生などのボタン。曲名は右の列、メニューは右の列の右上',
      (tester) async {
    await AppBoxes.loopItems.clear();
    await AppBoxes.loopItems.put('a', analyzed());
    tester.view.physicalSize = const Size(923, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: DetailScreen(itemId: 'a')),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final thumb = tester.getRect(find.byType(ItemThumbnail));
    // 画面の幅の半分くらいまで大きく、下は画面に収まる
    expect(thumb.width, greaterThan(923 * 0.45));
    expect(thumb.bottom, lessThanOrEqualTo(411));
    // 曲名はサムネの右、再生はサムネのすぐ下（左の列）で画面に収まる
    expect(tester.getRect(find.text('曲')).left, greaterThan(thumb.right));
    final play = tester.getRect(find.ancestor(
        of: find.text('再生'), matching: find.byType(InkWell)).first);
    expect(play.top, greaterThan(thumb.bottom));
    expect(play.top - thumb.bottom, lessThan(16));
    expect(play.left, closeTo(thumb.left, 1));
    expect(play.bottom, lessThanOrEqualTo(411));
    // メニューは右の列の右上（曲名より上、画面の右端寄り）
    final menu = tester.getRect(find.byIcon(Icons.more_vert));
    expect(menu.left, greaterThan(thumb.right));
    expect(menu.right, greaterThan(923 - 60));
    expect(menu.bottom, lessThanOrEqualTo(tester.getRect(find.text('曲')).top));
    // 戻るは左上
    expect(tester.getRect(find.byType(BackButton)).right, lessThan(thumb.right));
  });

  testWidgets('再生などのボタンはサムネのすぐ下に大きく（再生は幅いっぱい）。曲名はその下', (tester) async {
    await pump(tester, analyzed());
    final thumb = tester.getRect(find.byType(ItemThumbnail));
    final play = tester.getRect(find.ancestor(
        of: find.text('再生'), matching: find.byType(InkWell)).first);
    expect(play.top, greaterThan(thumb.bottom));
    expect(play.top - thumb.bottom, lessThan(16));
    expect(play.height, greaterThanOrEqualTo(52));
    expect(play.width, greaterThan(thumb.width / 2));
    expect(tester.getRect(find.text('曲')).top, greaterThan(play.bottom));
  });

  testWidgets('区間が無ければ AB 区間は出さない。未解析ならつなぎやすい曲は押せない', (tester) async {
    await pump(
        tester, LoopItem(id: 'b', title: '曲', uri: 'u', sourceType: 'local'));
    expect(find.text('AB 区間'), findsNothing);
    expect(find.text('未解析'), findsOneWidget);
    // 押せる札だけ InkWell が付く（未解析のテンポ / キーは押すと解析）
    expect(
        find.ancestor(of: find.text('つなぎやすい曲'), matching: find.byType(InkWell)),
        findsNothing);
    expect(
        find.ancestor(of: find.text('未解析'), matching: find.byType(InkWell)),
        findsOneWidget);
  });
}
