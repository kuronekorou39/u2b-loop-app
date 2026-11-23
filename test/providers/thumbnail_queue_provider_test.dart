import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/core/utils/request_pacing.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/thumbnail_queue_provider.dart';

/// サムネイルの取得係: 1 件ずつ間隔を空け、一時停止・再開・割り込み・失敗を扱う
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  setUp(() async {
    await AppBoxes.settings.clear();
    await AppBoxes.loopItems.clear();
    for (var i = 0; i < 20; i++) {
      await AppBoxes.loopItems.put(
        'i$i',
        LoopItem(
          id: 'i$i',
          title: '曲$i',
          uri: '',
          sourceType: 'youtube',
          thumbnailUrl: 'https://i.ytimg.com/vi/$i/hqdefault.jpg',
        ),
      );
    }
  });

  late List<Duration> waits;

  (ProviderContainer, ThumbnailQueueNotifier) setUpJob(FetchThumbnail fetch) {
    waits = [];
    final container = ProviderContainer(overrides: [
      thumbnailQueueProvider.overrideWith((ref) => ThumbnailQueueNotifier(
            ref,
            fetch: fetch,
            pacing: RequestPacing(),
            wait: (d) async => waits.add(d),
          )),
    ]);
    addTearDown(container.dispose);
    return (container, container.read(thumbnailQueueProvider.notifier));
  }

  Future<void> settle([int turns = 400]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> untilIdle(ProviderContainer c) async {
    for (var i = 0; i < 4000 && c.read(thumbnailQueueProvider) != null; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.read(thumbnailQueueProvider), isNull);
    await settle(20);
  }

  bool flag(String key) =>
      AppBoxes.settings.get(key, defaultValue: false) as bool;
  int saved() =>
      AppBoxes.loopItems.values.where((i) => i.thumbnailPath != null).length;

  /// 1 件ずつ手で進められる取得
  (ProviderContainer, ThumbnailQueueNotifier, List<(String, Completer<String?>)>)
      gatedJob() {
    final gates = <(String, Completer<String?>)>[];
    final (c, n) = setUpJob((item) {
      final g = Completer<String?>();
      gates.add((item.id, g));
      return g.future;
    });
    return (c, n, gates);
  }

  test('間隔は回数で伸びて上限で止まり、合計を先に計算できる', () {
    expect(RequestPacing.delayMsFor(1), 300);
    expect(RequestPacing.delayMsFor(10), 500);
    expect(RequestPacing.delayMsFor(1000), RequestPacing.maxMs);
    expect(RequestPacing().upcoming(20).inMilliseconds, 8400);
  });

  test('1 件ずつ、決まった間隔を空けて全部取る', () async {
    var active = 0, peak = 0;
    final (c, n) = setUpJob((item) async {
      peak = ++active > peak ? active : peak;
      await Future<void>.delayed(Duration.zero);
      active--;
      return '/t/${item.id}.jpg';
    });
    await n.startAll();
    expect(flag(SettingsKeys.thumbnailQueuePending), isTrue);
    await untilIdle(c);
    expect(peak, 1);
    expect(waits.first.inMilliseconds, 300);
    expect(waits[9].inMilliseconds, 500);
    expect(saved(), 20);
    expect(flag(SettingsKeys.thumbnailQueuePending), isFalse);
  });

  test('残り時間は 1 件目を取る前から出ていて、進むと減る', () async {
    final seen = <Duration>[];
    late ProviderContainer c;
    final job = setUpJob((item) async {
      seen.add(c.read(thumbnailQueueProvider)!.remaining!);
      return '/t/${item.id}.jpg';
    });
    c = job.$1;
    await job.$2.startAll();
    await untilIdle(c);
    expect(seen.first.inMilliseconds, greaterThanOrEqualTo(8000));
    expect(seen.last < seen.first, isTrue);
  });

  test('一時停止すると取得中の 1 件で止まり、再開で続きから', () async {
    final (c, n, gates) = gatedJob();
    await n.startAll();
    await settle();
    n.pause();
    gates.single.$2.complete('/t/a.jpg');
    await settle();
    expect(gates.length, 1);
    expect(saved(), 1);
    expect(c.read(thumbnailQueueProvider)!.paused, isTrue);
    expect(flag(SettingsKeys.thumbnailQueuePaused), isTrue);

    n.resume();
    await settle();
    expect(gates.length, 2);
    gates[1].$2.complete('/t/b.jpg');
    await settle();
    expect(gates.length, 3);
    n.pause();
    gates[2].$2.complete('/t/c.jpg');
    await settle();
  });

  test('一時停止中でも、曲単体と再生する曲は取れる', () async {
    final (c, n, gates) = gatedJob();
    await n.startAll();
    await settle();
    n.pause();
    gates.single.$2.complete('/t/a.jpg');
    await settle();

    final single = n.fetchNow('i15');
    await settle();
    expect(gates.last.$1, 'i15');
    gates.last.$2.complete('/t/15.jpg');
    expect(await single, isTrue);
    await settle();
    expect(AppBoxes.loopItems.get('i15')!.thumbnailPath, '/t/15.jpg');

    n.fetchIfMissing(AppBoxes.loopItems.get('i16')!);
    await settle();
    expect(gates.last.$1, 'i16');
    gates.last.$2.complete('/t/16.jpg');
    await settle();
    expect(c.read(thumbnailQueueProvider)!.paused, isTrue);
    expect(gates.length, 3);
  });

  test('再生する曲は列の先頭に割り込む', () async {
    final (_, n, gates) = gatedJob();
    await n.startAll();
    await settle();
    n.fetchIfMissing(AppBoxes.loopItems.get('i18')!);
    gates.single.$2.complete('/t/a.jpg');
    await settle();
    expect(gates[1].$1, 'i18');
    n.pause();
    gates[1].$2.complete('/t/b.jpg');
    await settle();
  });

  test('取得中に追加された曲は列の後ろに入り、件数が増える', () async {
    final (c, n, gates) = gatedJob();
    await n.startAll();
    await settle();
    await AppBoxes.loopItems.put(
        'new',
        LoopItem(
            id: 'new',
            title: '新',
            uri: '',
            sourceType: 'youtube',
            videoId: 'nnn'));
    n.enqueue(['new', 'new']);
    expect(c.read(thumbnailQueueProvider)!.total, 21);
    n.pause();
    gates.single.$2.complete('/t/a.jpg');
    await settle();
  });

  test('取れなかった曲は覚えて自動では取らず、手動なら取り直す', () async {
    var ok = false;
    final (c, n) = setUpJob((item) async =>
        item.id == 'i3' && !ok ? null : '/t/${item.id}.jpg');
    await n.startAll();
    await untilIdle(c);
    expect(AppBoxes.loopItems.get('i3')!.thumbnailPath, isNull);

    final item = AppBoxes.loopItems.get('i3')!;
    final before = waits.length;
    n.fetchIfMissing(item);
    await settle();
    expect(waits.length, before);

    ok = true;
    expect(await n.fetchNow('i3'), isTrue);
    expect(AppBoxes.loopItems.get('i3')!.thumbnailPath, isNotNull);
  });

  test('続けて失敗したら一時停止し、その分は失敗として残さない', () async {
    var calls = 0;
    final (c, n) = setUpJob((item) async {
      calls++;
      return null;
    });
    await n.startAll();
    await settle(1000);
    final s = c.read(thumbnailQueueProvider)!;
    expect(s.paused, isTrue);
    expect(calls, ThumbnailQueueNotifier.failStreakLimit);
    expect(s.done, 0);
    expect(s.failed, 0);
    expect(AppBoxes.settings.get(SettingsKeys.thumbnailFailedIds), isEmpty);
  });

  test('取得の間に消された曲は書き戻さない', () async {
    final (c, n) = setUpJob((item) async {
      if (item.id == 'i0') await AppBoxes.loopItems.delete('i0');
      return '/t/${item.id}.jpg';
    });
    await n.startAll();
    await untilIdle(c);
    expect(AppBoxes.loopItems.containsKey('i0'), isFalse);
    expect(AppBoxes.loopItems.length, 19);
  });

  test('途中でアプリが終わっていたら次の起動で続きから', () async {
    await AppBoxes.settings.put(SettingsKeys.thumbnailQueuePending, true);
    final (c, n) = setUpJob((item) async => '/t/${item.id}.jpg');
    await n.restoreOnLaunch();
    await untilIdle(c);
    expect(saved(), 20);
    expect(flag(SettingsKeys.thumbnailQueuePending), isFalse);
  });

  test('一時停止のまま閉じたら、次の起動でも止まったまま', () async {
    await AppBoxes.settings.put(SettingsKeys.thumbnailQueuePending, true);
    await AppBoxes.settings.put(SettingsKeys.thumbnailQueuePaused, true);
    var calls = 0;
    final (c, n) = setUpJob((item) async {
      calls++;
      return '/t/${item.id}.jpg';
    });
    await n.restoreOnLaunch();
    await settle();
    expect(calls, 0);
    expect(c.read(thumbnailQueueProvider)!.total, 20);
    n.resume();
    await untilIdle(c);
    expect(saved(), 20);
  });

  test('列を空にすると状態も消える', () async {
    final (c, n, gates) = gatedJob();
    await n.startAll();
    await settle();
    n.clear();
    expect(c.read(thumbnailQueueProvider), isNull);
    gates.single.$2.complete('/t/a.jpg');
    await settle();
    expect(gates.length, 1);
    expect(flag(SettingsKeys.thumbnailQueuePending), isFalse);
  });
}
