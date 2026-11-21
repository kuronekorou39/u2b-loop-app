import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:u2b_loop_app/core/audio/audio_quality.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/services/playback/media_opener.dart';

/// 呼ばれた順を記録するプレイヤー。platform は null なので音声フィルタ等は何もしない
class _FakePlayer implements Player {
  _FakePlayer({this.durationAfterOpen = const Duration(minutes: 3), double volume = 100})
      : _state = PlayerState(volume: volume);

  /// 開いた直後に分かる長さ（zero なら無音で鳴らすまで分からない）
  final Duration durationAfterOpen;
  final calls = <String>[];
  PlayerState _state;
  void Function()? onOpen;

  @override
  PlatformPlayer? platform;

  @override
  PlayerState get state => _state;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    calls.add('open:${media.uri} play=$play');
    _state = _state.copyWith(
        playlist: Playlist([media]), duration: durationAfterOpen);
    onOpen?.call();
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _state = _state.copyWith(duration: const Duration(minutes: 3));
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration d) async => calls.add('seek:${d.inMilliseconds}');

  @override
  Future<void> setVolume(double v) async {
    calls.add('volume:${v.toInt()}');
    _state = _state.copyWith(volume: v);
  }

  @override
  Future<void> setRate(double r) async => calls.add('rate:$r');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 曲を開く共通の手順（再生画面と、プレイリストの先読み・遷移の両方が通る）
void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('u2b_opener_test');
    Hive.init(dir.path);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  LoopItem local({double speed = 1.0, String? cachedVideoPath}) => LoopItem(
        id: 'a',
        title: '曲',
        uri: '/music/a.mp4',
        sourceType: SourceTypes.local,
        speed: speed,
        cachedVideoPath: cachedVideoPath,
      );

  /// [active] が「鳴っている側」のプレイヤー
  ProviderContainer containerFor(Player active) {
    final c = ProviderContainer(
        overrides: [playerProvider.overrideWithValue(active)]);
    addTearDown(c.dispose);
    return c;
  }

  Future<OpenedMedia?> open(
    ProviderContainer c,
    Player player,
    LoopItem item, {
    bool Function()? isCancelled,
    Duration Function()? startAt,
    bool waitForMetadata = true,
    void Function(OpenedMedia)? onOpened,
    void Function(double, String)? onStep,
  }) =>
      MediaOpener(c.read,
              isCancelled: isCancelled ?? () => false, onStep: onStep, logTag: 'テスト')
          .open(
        player,
        item,
        startAt: startAt ?? () => const Duration(seconds: 5),
        metadataWait: const Duration(milliseconds: 300),
        hqAudioWait: const Duration(milliseconds: 100),
        waitForMetadata: waitForMetadata,
        onOpened: onOpened,
      );

  test('ローカルの曲: 再生せずに開き、開始位置へシークして毎回速度を設定する', () async {
    final p = _FakePlayer();
    final c = containerFor(p);
    final m = await open(c, p, local(speed: 1.25));
    expect(m!.origin, MediaOrigin.local);
    expect(m.uri, '/music/a.mp4');
    expect(m.manifest, isNull);
    expect(p.calls, ['open:/music/a.mp4 play=false', 'seek:5000', 'rate:1.25']);
    expect(c.read(audioQualityProvider)[p], AudioQuality.local);
  });

  test('オフライン保存があればそのファイルを開く', () async {
    final file = File('${dir.path}/saved.mp4')..writeAsBytesSync([0]);
    final p = _FakePlayer();
    final c = containerFor(p);
    final m = await open(c, p, local(cachedVideoPath: file.path));
    expect(m!.origin, MediaOrigin.offline);
    expect(m.uri, file.path);
    expect(p.calls.first, startsWith('open:'));
    expect(p.calls.first, contains('saved.mp4'));
    expect(c.read(audioQualityProvider)[p], AudioQuality.offline);
  });

  test('長さが分からなければ無音で鳴らして確かめ、音量を戻してからシークする', () async {
    final p = _FakePlayer(durationAfterOpen: Duration.zero, volume: 70);
    final c = containerFor(p);
    await open(c, p, local());
    expect(p.calls, [
      'open:/music/a.mp4 play=false',
      'volume:0',
      'play',
      'pause',
      'volume:70',
      'seek:5000',
      'rate:1.0',
    ]);
  });

  test('先読み側のプレイヤーは、鳴っている側の音量に戻す（前の曲のフェードで 0 のことがある）', () async {
    final active = _FakePlayer(volume: 80);
    final preload = _FakePlayer(durationAfterOpen: Duration.zero, volume: 0);
    final c = containerFor(active);
    await open(c, preload, local());
    expect(preload.calls, contains('volume:80'));
    expect(active.calls, isEmpty, reason: '鳴っている側には触らない');
  });

  test('waitForMetadata が false なら長さを確かめない', () async {
    final p = _FakePlayer(durationAfterOpen: Duration.zero);
    final c = containerFor(p);
    await open(c, p, local(), waitForMetadata: false);
    expect(p.calls, isNot(contains('play')));
  });

  test('開いた後で打ち切られたら null を返し、シークも速度の設定もしない', () async {
    var cancelled = false;
    final p = _FakePlayer()..onOpen = () => cancelled = true;
    final c = containerFor(p);
    final m = await open(c, p, local(), isCancelled: () => cancelled);
    expect(m, isNull);
    expect(p.calls, ['open:/music/a.mp4 play=false']);
  });

  test('onOpened は開いた直後（長さを確かめる前）。開始位置は開いた後で決める', () async {
    final p = _FakePlayer(durationAfterOpen: Duration.zero);
    final c = containerFor(p);
    var start = Duration.zero;
    int? callsAtOpened;
    await open(c, p, local(), onOpened: (_) {
      callsAtOpened = p.calls.length;
      start = const Duration(seconds: 42);
    }, startAt: () => start);
    expect(callsAtOpened, 1, reason: 'open のすぐ後');
    expect(p.calls, contains('seek:42000'));
  });

  test('進み具合は増えていく', () async {
    final p = _FakePlayer(durationAfterOpen: Duration.zero);
    final c = containerFor(p);
    final steps = <double>[];
    await open(c, p, local(), onStep: (v, _) => steps.add(v));
    expect(steps, isNotEmpty);
    expect(steps, orderedEquals([...steps]..sort()));
  });
}
