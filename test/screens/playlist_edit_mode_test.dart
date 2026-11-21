import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/core/ui/app_snack_bar.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/screens/playlist_detail_screen.dart';

/// プレイリスト詳細の編集モード: ふだんは並べ替え・外すが出ない。編集モードでは確認なしで
/// 外せて、通知の「元に戻す」で戻る。共有・削除はメニューに
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

  setUp(() async {
    await AppBoxes.loopItems.clear();
    await AppBoxes.playlists.clear();
    for (final id in ['a', 'b', 'c']) {
      await AppBoxes.loopItems
          .put(id, LoopItem(id: id, title: '曲 $id', uri: 'u', sourceType: 'local'));
    }
    await AppBoxes.playlists
        .put('p', Playlist(id: 'p', name: 'リスト', itemIds: ['a', 'b', 'c']));
    AppToast.instance.hide();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 2280);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: const PlaylistDetailScreen(playlistId: 'p'),
        builder: (context, child) =>
            Stack(children: [child!, const AppToastHost(bottom: 0)]),
      ),
    ));
    await tester.pumpAndSettle();
  }

  List<String> ids() => AppBoxes.playlists.get('p')!.itemIds;

  testWidgets('表示の切り替え: リスト小は曲名だけ。自動で入れるタグが 1 つなら行には出さない',
      (tester) async {
    await AppBoxes.tags.put('r', Tag(id: 'r', name: 'ロック'));
    await AppBoxes.tags.put('j', Tag(id: 'j', name: 'ジャズ'));
    addTearDown(() => AppBoxes.tags.clear());
    addTearDown(
        () => AppBoxes.settings.delete(SettingsKeys.playlistDetailCompact));
    await AppBoxes.loopItems.put(
        'a',
        LoopItem(
            id: 'a',
            title: '曲 a',
            uri: 'u',
            sourceType: 'local',
            speed: 1.5,
            tagIds: ['r', 'j']));
    await AppBoxes.playlists.put(
        'p', Playlist(id: 'p', name: 'リスト', itemIds: ['a', 'b', 'c'], tagIds: ['r']));
    await pump(tester);
    expect(find.text('タグを紐づける'), findsNothing);
    // 見出しに 1 つ（自動で入れるタグ）。行にはロックを出さず、ジャズだけ
    expect(find.text('ロック'), findsOneWidget);
    expect(find.text('ジャズ'), findsOneWidget);
    expect(find.textContaining('1.5'), findsOneWidget);

    await tester.tap(find.byTooltip('表示: リスト大'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('表示: リスト小'), findsOneWidget);
    expect(find.text('ジャズ'), findsNothing);
    expect(find.textContaining('1.5'), findsNothing);
    expect(find.text('曲 a'), findsOneWidget);
    expect(AppBoxes.settings.get(SettingsKeys.playlistDetailCompact), isTrue);
  });

  testWidgets('ふだんは ⋮ だけ（≡ も ⊖ も無く、右に余白を取らない）', (tester) async {
    await pump(tester);
    // タグが無いプレイリストにも、紐づける入口がある
    await tester.tap(find.text('タグを紐づける'));
    await tester.pumpAndSettle();
    expect(find.text('タグで自動追加'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.byTooltip('プレイリストから外す'), findsNothing);
    expect(find.byTooltip('メニュー'), findsNWidgets(3));
  });

  testWidgets('並べ替えモード: 同じボタンでオンオフ。⋮ の場所が ≡ になり、触れてすぐ動かせる',
      (tester) async {
    await pump(tester);
    final menu = tester.getCenter(find.byTooltip('メニュー').first);
    final button = tester.getCenter(find.byTooltip('並べ替え'));
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    // ボタンは同じ場所で緑になる
    expect(tester.getCenter(find.byTooltip('並べ替えを終える')), button);
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.swap_vert))
            .color,
        isNotNull);
    expect(find.byTooltip('メニュー'), findsNothing);
    final handles = find.byIcon(Icons.drag_handle);
    expect(tester.getCenter(handles.first), menu);

    // タップしても開かない
    await tester.tap(find.text('曲 b'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
    expect(find.byTooltip('並べ替えを終える'), findsOneWidget);

    // ≡ は長押しを待たずに動かせる
    final from = tester.getCenter(handles.at(0));
    final to = tester.getCenter(handles.at(2)) + const Offset(0, 40);
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    for (var k = 1; k <= 10; k++) {
      await g.moveTo(Offset.lerp(from, to, k / 10)!);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(ids().last, 'a');

    // 戻るキーは並べ替えモードを抜けるだけ
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('並べ替え'), findsOneWidget);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
  });

  testWidgets('並べ替えモード中は写真・名前を暗くして触れず、再生・シャッフル・⋮・表示の切り替えは隠す（場所は残す）',
      (tester) async {
    await pump(tester);
    double opacityOf(Finder finder) {
      var o = 1.0;
      for (final w in tester.widgetList(find.ancestor(
          of: finder.first,
          matching: find.byWidgetPredicate(
              (w) => w is Opacity || w is AnimatedOpacity)))) {
        o *= w is Opacity ? w.opacity : (w as AnimatedOpacity).opacity;
      }
      return o;
    }

    final play = tester.getRect(find.text('再生'));
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    expect(opacityOf(find.text('リスト')), lessThan(0.5), reason: 'プレイリストの名前は暗く');
    expect(opacityOf(find.text('再生')), 0);
    expect(opacityOf(find.text('シャッフル')), 0);
    expect(opacityOf(find.byTooltip('その他')), 0);
    expect(opacityOf(find.byTooltip('名前を変更')), 0);
    expect(opacityOf(find.byTooltip('サムネイルを選ぶ')), 0);
    expect(tester.getRect(find.text('再生')), play, reason: '場所は残す（一覧が動かない）');
    // 一覧はそのまま（暗くしない）
    expect(opacityOf(find.text('曲 a')), 1);
    // 隠した ⋮ は押せない
    await tester.tap(find.byTooltip('その他'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('プレイリストを削除'), findsNothing);
    // 抜けると戻る
    await tester.tap(find.byTooltip('並べ替えを終える'));
    await tester.pumpAndSettle();
    expect(opacityOf(find.text('再生')), 1);
    expect(opacityOf(find.text('リスト')), 1);
  });

  testWidgets('並べ替えモードは行の長押しでも持ち上げて並べ替えられる', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('並べ替え'));
    await tester.pumpAndSettle();
    final from = tester.getCenter(find.text('曲 a'));
    final to = tester.getCenter(find.text('曲 c'));
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 600));
    for (var k = 1; k <= 10; k++) {
      await g.moveTo(Offset(from.dx, from.dy + (to.dy + 40 - from.dy) * k / 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(ids().last, 'a');
  });

  testWidgets('長押しで選択に入る。タップで切り替え、まとめて外せて「元に戻す」で戻る', (tester) async {
    await pump(tester);
    final name = tester.getRect(find.text('曲 a'));
    await tester.longPress(find.text('曲 a'));
    await tester.pumpAndSettle();
    expect(find.text('1 曲を選択'), findsOneWidget);
    expect(find.byTooltip('並べ替え'), findsNothing);
    expect(find.byTooltip('その他'), findsNothing);
    // 選択に入っても曲名は動かない
    expect(tester.getRect(find.text('曲 a')), name);

    // 選択中のタップは開かずに切り替え
    await tester.tap(find.text('曲 c'));
    await tester.pumpAndSettle();
    expect(find.text('2 曲を選択'), findsOneWidget);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);

    await tester.tap(find.byTooltip('プレイリストから外す'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: '確認は出さない');
    expect(ids(), ['b']);
    expect(find.text('2 曲をプレイリストから外しました'), findsOneWidget);
    expect(find.text('プレイリスト'), findsOneWidget, reason: '選択は終わる');

    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(ids(), ['a', 'b', 'c']);
  });

  testWidgets('選択: 全選択、外して 0 件になれば抜ける、戻るキーは選択をやめるだけ', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('曲 b'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全選択'));
    await tester.pumpAndSettle();
    expect(find.text('3 曲を選択'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
    expect(find.byTooltip('並べ替え'), findsOneWidget);

    await tester.longPress(find.text('曲 b'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲 b'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('並べ替え'), findsOneWidget);
    expect(ids(), ['a', 'b', 'c']);
  });

  testWidgets('共有と削除はメニューの中', (tester) async {
    await pump(tester);
    expect(find.byTooltip('共有'), findsNothing);
    await tester.tap(find.byTooltip('その他'));
    await tester.pumpAndSettle();
    expect(find.text('共有'), findsOneWidget);
    expect(find.text('プレイリストを削除'), findsOneWidget);
  });

  testWidgets('通知は時間が来たら消える（ボタン付きでも）', (tester) async {
    await pump(tester);
    AppToast.instance.show(AppSnackBar.action('外しました', label: '元に戻す', onPressed: () {}));
    await tester.pump();
    expect(find.text('外しました'), findsOneWidget);
    await tester.pump(AppSnackBar.actionDuration + const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('外しました'), findsNothing);
  });

  testWidgets('横画面: AppBar の代わりに左の列の上に「プレイリスト」の行、曲の一覧は右で画面の上から',
      (tester) async {
    tester.view.physicalSize = const Size(2700, 1236);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: PlaylistDetailScreen(playlistId: 'p'))));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    final back = tester.getRect(find.byType(BackButton));
    final title = tester.getRect(find.text('リスト'));
    final play = tester.getRect(find.text('再生'));
    final song = tester.getRect(find.text('曲 a'));
    // 戻る → 名前 → 再生 の順に左の列を下へ。曲は右の列で、戻るの行と同じ高さから
    expect(title.top, greaterThan(back.bottom));
    expect(play.top, greaterThan(title.bottom));
    expect(song.left, greaterThan(play.right));
    expect(song.top, lessThan(title.top));
    expect(tester.takeException(), isNull);
  });
}
