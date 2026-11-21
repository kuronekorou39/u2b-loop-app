import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart' show PlatformPlayer, Player, PlayerState;
import 'package:u2b_loop_app/core/audio/sfx_library.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_state.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/playlist_track.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/providers/loop_provider.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';
import 'package:u2b_loop_app/providers/playlist_player_provider.dart';
import 'package:u2b_loop_app/services/playback/playlist_engine.dart';
import 'package:u2b_loop_app/services/tail_renderer.dart';
import 'package:u2b_loop_app/services/transition_sfx.dart';

class _FakePlayer implements Player {
  PlayerState _s = const PlayerState();
  int plays = 0;

  void place(Duration d, {Duration position = Duration.zero, bool playing = false}) =>
      _s = PlayerState(duration: d, position: position, playing: playing, rate: 1.0, volume: 100);

  @override
  PlayerState get state => _s;
  @override
  PlatformPlayer? platform;
  @override
  Future<void> seek(Duration d, {bool synchronized = true}) async =>
      _s = _s.copyWith(position: d);
  @override
  Future<void> play({bool synchronized = true}) async {
    plays++;
    _s = _s.copyWith(playing: true);
  }

  @override
  Future<void> pause({bool synchronized = true}) async => _s = _s.copyWith(playing: false);
  @override
  Future<void> setVolume(double v, {bool synchronized = true}) async =>
      _s = _s.copyWith(volume: v);
  @override
  Future<void> setRate(double r, {bool synchronized = true}) async => _s = _s.copyWith(rate: r);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeLoop extends StateNotifier<LoopState> implements LoopNotifier {
  _FakeLoop(super.s);
  @override
  void Function()? onTrackEnd;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSfx implements TransitionSfx {
  int starts = 0;
  @override
  Future<void> load(List<SfxClip> clips) async {}
  @override
  Future<void> start({required double volume, double rate = 1}) async => starts++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 1 番の終わり方: エコー・残響は B 点まで前の曲だけ鳴らし、次の曲を B 点で頭から
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  const cut = Duration(seconds: 60);
  late _FakePlayer outP, inP;
  late _FakeSfx sfx;
  late ProviderContainer container;
  late PlaylistEngine engine;
  late LoopItem outItem, inItem;
  late PlaylistTrack next;

  String tailKey(TransitionEffect effect) => TailRequest(
        effect: effect,
        item: outItem,
        cutMs: cut.inMilliseconds.toDouble(),
        beatMediaMs: 500,
        outRate: 1,
      ).key;

  void renderTail(TransitionEffect effect) => TailRenderer.debugSetReady(
      tailKey(effect), const SfxClip.rendered(SfxRole.tail, '/tmp/tail.wav', 2000));

  Future<void> setUpEngine({String? ending = 'echo', bool firstVerse = true}) async {
    await AppBoxes.loopItems.clear();
    await AppBoxes.settings.clear();
    await AppBoxes.settings.put(SettingsKeys.crossfadeBeats, 16);
    outItem = LoopItem(
      id: 'out',
      title: 'out',
      uri: 'u',
      sourceType: SourceTypes.local,
      bpm: 120,
      beatBpm: 120,
      beatOffsetMs: 0,
      beatConfidence: 1,
      durationMs: 180000,
      firstVerseEnding: ending,
    );
    inItem = LoopItem(
      id: 'in',
      title: 'in',
      uri: 'u',
      sourceType: SourceTypes.local,
      bpm: 123,
      beatBpm: 123,
      beatOffsetMs: 40,
      beatConfidence: 1,
      leadingSilenceMs: 1500,
      mixInMs: 30000,
      durationMs: 200000,
    );
    await AppBoxes.loopItems.put('out', outItem);
    await AppBoxes.loopItems.put('in', inItem);
    outP = _FakePlayer()..place(const Duration(minutes: 3));
    inP = _FakePlayer()..place(const Duration(seconds: 200));
    sfx = _FakeSfx();
    container = ProviderContainer(overrides: [
      playerAProvider.overrideWithValue(outP),
      playerBProvider.overrideWithValue(inP),
      playerCProvider.overrideWithValue(_FakePlayer()),
      transitionSfxProvider.overrideWithValue(sfx),
      loopProvider.overrideWith((ref) => _FakeLoop(
          const LoopState(pointA: Duration.zero, pointB: cut, enabled: true))),
    ]);
    addTearDown(() {
      TailRenderer.debugSetReady(null, null);
      container.dispose();
    });
    engine = container.read(playlistEngineProvider);
    final playlist = container.read(playlistPlayerProvider.notifier);
    playlist.loadPlaylist([outItem, inItem]);
    if (firstVerse) playlist.toggleFirstVerseMode();
    next = PlaylistTrack(item: inItem, itemIndex: 1);
    // 読み込みのため
    container.read(loopItemsProvider);
  }

  group('つなぎ方の決定', () {
    test('エコーを選んで尾ができていれば、次の曲は頭から・速度はそのまま', () async {
      await setUpEngine();
      renderTail(TransitionEffect.echoTail);
      final r = engine.recipeFor(next);
      expect(r.effect, TransitionEffect.echoTail);
      expect(r.holdsIn, isTrue);
      expect(r.tempoMatch, isFalse);
      expect(engine.effectiveStart(next), const Duration(milliseconds: 1500));
      expect(engine.inAtMs(next), 1500);
      expect(engine.plannedInStart(next, inRate: 1), const Duration(milliseconds: 1500));
    });

    test('残響も同じ', () async {
      await setUpEngine(ending: 'reverb');
      renderTail(TransitionEffect.reverbTail);
      final r = engine.recipeFor(next);
      expect(r.effect, TransitionEffect.reverbTail);
      expect(r.holdsIn, isTrue);
    });

    test('次の曲の 1 番の始まりが決まっていればそこから', () async {
      await setUpEngine();
      inItem.firstVerseAMs = 8000;
      renderTail(TransitionEffect.echoTail);
      expect(engine.effectiveStart(next), const Duration(seconds: 8));
    });

    test('尾の音がまだ無ければ、ふだんのつなぎ（ぶつ切れにしない）', () async {
      await setUpEngine();
      expect(engine.recipeFor(next).holdsIn, isFalse);
    });

    test('重ねるを選んだ曲は尾があってもふだんのつなぎ', () async {
      await setUpEngine(ending: null);
      renderTail(TransitionEffect.echoTail);
      expect(engine.recipeFor(next).holdsIn, isFalse);
    });

    test('1 番だけモードでなければ使わない', () async {
      await setUpEngine(firstVerse: false);
      renderTail(TransitionEffect.echoTail);
      expect(engine.recipeFor(next).holdsIn, isFalse);
    });

    test('クロスフェードがオフなら使わない', () async {
      await setUpEngine();
      await AppBoxes.settings.put(SettingsKeys.crossfadeBeats, 0);
      container.invalidate(crossfadeProvider);
      renderTail(TransitionEffect.echoTail);
      expect(engine.recipeFor(next).holdsIn, isFalse);
      expect(engine.crossfadeDuration, Duration.zero);
    });
  });

  testWidgets('切替点までは次の曲を鳴らさず、前の曲は 100% のまま。切替点で次の曲が鳴る', (tester) async {
    await tester.runAsync(() => setUpEngine());
    renderTail(TransitionEffect.echoTail);
    // 切替点の 0.8 秒前（交差の長さは 2 拍 = 1 秒）
    outP.place(const Duration(minutes: 3),
        position: const Duration(milliseconds: 59200), playing: true);
    engine.armCrossfade(next);
    await tester.pump(const Duration(milliseconds: 150));
    expect(engine.isCrossfading, isTrue);
    expect(inP.plays, 0, reason: '切替点の前は次の曲を止めておく');
    expect(inP.state.position, const Duration(milliseconds: 1500));
    expect(outP.state.volume, 100);
    expect(inP.state.volume, 0);

    await tester.pump(const Duration(milliseconds: 750));
    expect(inP.plays, 1, reason: '切替点で鳴らし始める');
    expect(outP.state.volume, 0);
    expect(inP.state.volume, 100);
    expect(sfx.starts, 1, reason: '尾を鳴らす');

    engine.disarmCrossfade();
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('切替点より前に取り消すと、次の曲は頭で止まったまま', (tester) async {
    await tester.runAsync(() => setUpEngine());
    renderTail(TransitionEffect.echoTail);
    outP.place(const Duration(minutes: 3),
        position: const Duration(milliseconds: 59200), playing: true);
    engine.armCrossfade(next);
    await tester.pump(const Duration(milliseconds: 150));
    expect(engine.isCrossfading, isTrue);
    engine.disarmCrossfade();
    await tester.pump(const Duration(seconds: 2));
    expect(inP.plays, 0);
    expect(inP.state.position, const Duration(milliseconds: 1500));
    expect(outP.state.volume, 100);
  });
}
