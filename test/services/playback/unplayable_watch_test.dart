import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/providers/playlist_player_provider.dart';
import 'package:u2b_loop_app/services/playback/unplayable_watch.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// YouTube の情報取得の結果を曲に残す: ずっと再生できない理由なら残して飛ばし、取れたら消す
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  late ProviderContainer container;
  setUp(() async {
    await AppBoxes.loopItems.clear();
    for (final id in ['a', 'b']) {
      await AppBoxes.loopItems.put(id,
          LoopItem(id: id, title: id, uri: 'u', sourceType: SourceTypes.youtube, videoId: id));
    }
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  LoopItem item(String id) => AppBoxes.loopItems.get(id)!;
  LoopItemsNotifier items() => container.read(loopItemsProvider.notifier);

  test('年齢制限なら曲に残し、鳴らしているプレイリストでは飛ばす', () async {
    final playlist = PlaylistPlayerNotifier()..loadPlaylist([item('a'), item('b')]);
    await expectLater(
      UnplayableWatch.fetch(items(), playlist, item('b'), () async {
        throw VideoUnplayableException.unplayable(VideoId('qk0ng1HTM-Y'),
            reason: 'Sign in to confirm your age');
      }),
      throwsA(isA<VideoUnplayableException>()),
    );
    expect(item('b').unplayableReason, contains('年齢制限'));
    expect(playlist.currentState.peekNextTrackIndex(), isNull);
  });

  test('通信エラーは残さない。取れたら残っていた理由を消す', () async {
    await expectLater(
      UnplayableWatch.fetch(items(), null, item('a'), () async {
        throw const SocketException('x');
      }),
      throwsA(isA<SocketException>()),
    );
    expect(item('a').isUnplayable, isFalse);

    await items().setUnplayable('a', '年齢制限');
    expect(await UnplayableWatch.fetch(items(), null, item('a'), () async => 1), 1);
    expect(item('a').isUnplayable, isFalse);
  });
}
