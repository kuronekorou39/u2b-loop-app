import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/services/cache_service.dart';
import 'package:u2b_loop_app/services/export_source.dart';
import 'package:u2b_loop_app/services/save_flow.dart';

/// 保存シート: アプリ内に保存 / 端末に書き出しを 1 つのシートで選ぶ
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });

  tearDownAll(() => Hive.close());

  setUp(() => AppBoxes.settings.clear());

  CacheQuality q(String label) =>
      CacheQuality(label: label, needsMerge: false, videoTag: 0);

  test('アプリ内保存の画質は、選んだ高さ以下で最大のもの', () {
    final options = [q('1080p'), q('720p60'), q('360p')];
    expect(SaveFlow.pickCacheQuality(options, 720)?.label, '720p60');
    expect(SaveFlow.pickCacheQuality(options, 480)?.label, '360p');
    expect(SaveFlow.pickCacheQuality([q('720p')], 360)?.label, '720p');
    expect(SaveFlow.pickCacheQuality(const [], 720), isNull);
  });

  Future<Future<SaveChoice?> Function()> openSheet(WidgetTester tester,
      {String? rangeText, bool offline = true}) async {
    SaveChoice? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await SaveFlow.showSheet(ctx,
                  title: '曲', rangeText: rangeText, offline: offline);
              done = true;
            },
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    return () async {
      expect(done, isTrue);
      return result;
    };
  }

  testWidgets('既定はアプリ内に保存。音質と範囲は書き出しのときだけ', (tester) async {
    final result = await openSheet(tester, rangeText: '0:10 - 0:40');
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('アプリ内に保存'), findsOneWidget);
    expect(find.text('範囲'), findsNothing);

    await tester.tap(find.text('端末に書き出し'));
    await tester.pumpAndSettle();
    expect(find.text('範囲'), findsOneWidget);
    expect(find.text('音質'), findsNothing); // 動画のときは出さない
    await tester.tap(find.text('音声のみ'));
    await tester.pumpAndSettle();
    expect(find.text('音質'), findsOneWidget);
    expect(find.text('画質'), findsNothing);
    await tester.tap(find.text('曲全体'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('書き出し'));
    await tester.pumpAndSettle();
    final choice = (await result())!;
    expect(choice.target, SaveTarget.device);
    expect(choice.audioOnly, isTrue);
    expect(choice.wholeTrack, isTrue);
    expect(choice.hqAudio, isTrue);
    // 次に開いたときの既定として覚える
    expect(AppBoxes.settings.get(SettingsKeys.saveTarget), 'device');
  });

  testWidgets('アプリ内に保存できない曲は保存先を出さず書き出しになる', (tester) async {
    final result = await openSheet(tester, offline: false);
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('保存先'), findsNothing);
    await tester.tap(find.text('書き出し'));
    await tester.pumpAndSettle();
    final choice = (await result())!;
    expect(choice.target, SaveTarget.device);
    expect(choice.quality, ExportQuality.p720);
  });

  testWidgets('スマホの幅（360）でもはみ出さない', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openSheet(tester, rangeText: '0:10 - 0:40');
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('端末に書き出し'));
    await tester.tap(find.text('音声のみ'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
