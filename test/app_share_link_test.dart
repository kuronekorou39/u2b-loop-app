import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:u2b_loop_app/app.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/core/ui/app_snack_bar.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/services/share_service.dart';

/// 共有リンク（u2bloop://）でアプリを開く。
/// Android 側（app_links）は、起動時のリンクを getInitialLink でも返し、
/// 最初に購読したときにもストリームへ 1 回流す。両方を読むと受信の画面が 2 枚重なる
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
    PackageInfo.setMockInitialValues(
      appName: 'U2B Loop',
      packageName: 'test',
      version: '1.0.0',
      buildNumber: '',
      buildSignature: '',
    );
  });
  tearDownAll(() => Hive.close());

  // AppLinks はアプリに 1 つなので、起動 → 起動中の受信の順に 1 本で確かめる
  testWidgets('起動時のリンクでも起動中のリンクでも受信の画面は 1 枚。壊れたリンクは通知', (tester) async {
    final link = ShareService.encode(
      playlistName: 'リスト',
      items: [
        LoopItem(
          id: 'a',
          title: '曲',
          uri: '',
          sourceType: SourceTypes.youtube,
          videoId: 'aaaaaaaaaaa',
        ),
      ],
      tagIdToName: const {},
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    const method = MethodChannel('com.llfbandit.app_links/messages');
    const events = EventChannel('com.llfbandit.app_links/events');
    MockStreamHandlerEventSink? sink;
    messenger.setMockMethodCallHandler(method,
        (call) async => call.method == 'getInitialLink' ? link : null);
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, s) {
        sink = s;
        s.success(link);
      }),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(events, null);
    });
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    final dialog = find.text('プレイリストを受信');

    await tester.pumpWidget(const ProviderScope(child: App()));
    await settle();
    expect(dialog, findsOneWidget, reason: '起動時のリンク');

    await tester.tap(find.text('キャンセル'));
    await settle();
    expect(dialog, findsNothing);

    sink!.success(link);
    await settle();
    expect(dialog, findsOneWidget, reason: '起動中に届いたリンク');
    await tester.tap(find.text('キャンセル'));
    await settle();

    sink!.success('u2bloop://share/broken');
    await settle();
    expect(dialog, findsNothing);
    expect(find.text('無効な共有URLです'), findsOneWidget);

    AppToast.instance.hide();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
