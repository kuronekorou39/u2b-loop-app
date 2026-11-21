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
