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

  testWidgets('ふだんは並べ替えの ≡ も外す ⊖ も見えない', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.drag_handle).hitTestable(), findsNothing);
    expect(find.byTooltip('プレイリストから外す'), findsNothing);
    expect(find.byTooltip('メニュー'), findsNWidgets(3));
  });

  testWidgets('編集モードでは確認なしで外し、「元に戻す」で戻る。曲名の幅は変わらない', (tester) async {
    await pump(tester);
    final before = tester.getRect(find.text('曲 b'));
    await tester.tap(find.byTooltip('編集（並べ替え・外す）'));
    await tester.pumpAndSettle();
    expect(find.text('完了'), findsOneWidget);
    expect(tester.getRect(find.text('曲 b')).width, before.width);
    expect(find.byIcon(Icons.drag_handle).hitTestable(), findsNWidgets(3));

    await tester.tap(find.byTooltip('プレイリストから外す').at(1));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: '確認は出さない');
    expect(ids(), ['a', 'c']);
    expect(find.text('「曲 b」をプレイリストから外しました'), findsOneWidget);

    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(ids(), ['a', 'b', 'c']);

    // 戻るキーは編集モードを抜けるだけ
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('完了'), findsNothing);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
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
}
