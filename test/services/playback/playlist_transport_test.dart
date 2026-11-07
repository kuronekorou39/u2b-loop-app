import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_state.dart';
import 'package:u2b_loop_app/models/playlist_mode.dart' as pl;
import 'package:u2b_loop_app/models/playlist_track.dart';
import 'package:u2b_loop_app/providers/playlist_engine.dart';
import 'package:u2b_loop_app/providers/playlist_player_provider.dart';
import 'package:u2b_loop_app/services/playback/playlist_transport.dart';

LoopItem _item(String id) =>
    LoopItem(id: id, title: id, uri: 'file:///$id', sourceType: 'local');

/// 再生の土台の偽物。呼ばれたことを順に残し、先読みは手で終わらせる
class _FakeDeck implements TransportDeck {
  _FakeDeck(this.playlist);

  @override
  final PlaylistPlayerNotifier playlist;

  final calls = <String>[];
  final volumes = <double>[];
  Completer<Object?>? preloadGate;
  Completer<void>? activeGate;
  bool crossfading = false;
  bool fadeOn = false;
  String? parked;
  Duration pos = Duration.zero;
  Duration dur = const Duration(minutes: 3);
  bool Function()? bPoint;
  void Function()? trackEnd;

  @override
  AdvanceReadiness readiness({int? preloadedIndex, int? pendingJumpIndex}) {
    // PlaylistEngine.readiness と同じ判定
    final ps = playlist.currentState;
    final nextIdx = ps.peekNextTrackIndex();
    if (nextIdx == null && pendingJumpIndex == null) {
      return AdvanceReadiness.none;
    }
    final current = ps.currentTrack;
    if (nextIdx != null &&
        current != null &&
        ps.tracks[nextIdx].isSameItem(current)) {
      return AdvanceReadiness.sameItem;
    }
    if (preloadedIndex != null &&
        (pendingJumpIndex == preloadedIndex || nextIdx == preloadedIndex)) {
      return AdvanceReadiness.preloaded;
    }
    return AdvanceReadiness.notReady;
  }

  @override
  Future<Object?> preparePreload(PlaylistTrack track,
      {required bool Function() isStale}) {
    calls.add('preparePreload ${track.item.id}');
    preloadGate = Completer<Object?>();
    return preloadGate!.future;
  }

  @override
  Future<void> prepareActive(PlaylistTrack track,
      {required bool Function() isStale}) {
    calls.add('prepareActive ${track.item.id}');
    activeGate = Completer<void>();
    return activeGate!.future;
  }

  @override
  void armCrossfade(PlaylistTrack next) => calls.add('arm ${next.item.id}');
  @override
  void disarmCrossfade() => calls.add('disarm');
  @override
  bool get isCrossfading => crossfading;
  @override
  void releaseParked() {}
  @override
  Future<void> pauseAtPlaylistEnd() async => calls.add('pauseAtEnd');
  @override
  String? get parkedItemId => parked;
  @override
  bool stepBackToParked(Duration position) {
    calls.add('stepBack');
    return true;
  }

  @override
  void swapSlots() => calls.add('swap');
  @override
  Duration get crossfadeDuration => Duration.zero;
  @override
  Duration? plannedCut() => null;
  @override
  bool get crossfadeOn => fadeOn;
  @override
  Duration get position => pos;
  @override
  Duration get duration => dur;
  @override
  void setVolume(double volume) => volumes.add(volume);
  @override
  void seek(Duration position) => calls.add('seek ${position.inMilliseconds}');
  @override
  void play() => calls.add('play');
  @override
  String? get activeOpenedUri => 'active';
  @override
  void stopPreload() => calls.add('stopPreload');
  @override
  String? get preloadOpenedUri => 'preloaded';
  @override
  LoopState get loopState => const LoopState();
  @override
  set onBPointReached(bool Function()? callback) => bPoint = callback;
  @override
  set onTrackEnd(void Function()? callback) => trackEnd = callback;
  @override
  void setCurrentItem(String? itemId) {}
}

class _FakeHost implements TransportHost {
  final calls = <String>[];
  @override
  bool mounted = true;
  @override
  bool initialLoading = false;
  @override
  void refresh() {}
  bool canReload = true;
  @override
  bool reloadCurrent() {
    calls.add('reload');
    return canReload;
  }
  @override
  void loadTrackRegion(PlaylistTrack track) =>
      calls.add('region ${track.item.id}');
  @override
  void showSource(PlaylistTrack track, {String? openedUri}) =>
      calls.add('source ${track.item.id} ${openedUri ?? '-'}');
  @override
  void showWaveform(PlaylistTrack track) => calls.add('wave ${track.item.id}');
  @override
  void endLoading() {}
  @override
  void onTrackSwitched(PlaylistTrack track) =>
      calls.add('switched ${track.item.id}');
  @override
  void onPreloaded(PlaylistTrack track, Object? manifest,
          {required bool Function() stillCurrent}) =>
      calls.add('preloaded ${track.item.id}');
  @override
  double normalizedVolume(LoopItem item) => 80;
}

void main() {
  late PlaylistPlayerNotifier playlist;
  late _FakeDeck deck;
  late _FakeHost host;
  late PlaylistTransportController t;
  // 時間送り（tester.pump）に合わせて進める時計
  var clock = DateTime(2026);

  setUp(() {
    clock = DateTime(2026);
    playlist = PlaylistPlayerNotifier()
      ..loadPlaylist([_item('a'), _item('b'), _item('c')]);
    deck = _FakeDeck(playlist);
    host = _FakeHost();
    t = PlaylistTransportController(
        deck: deck, host: host, isPlaylist: true, now: () => clock)
      ..setupCallbacks();
  });

  /// 後に残ったタイマー（2 秒後の先読み・監視）を片付ける
  Future<void> finish(WidgetTester tester) async {
    t.dispose();
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('先読みが済むと予約し、B 点で先読み側に切り替える', (tester) async {
    unawaited(t.preloadNext());
    expect(t.isPreloading, isTrue);
    expect(t.preloadingIndex, 1);
    deck.preloadGate!.complete(null);
    await tester.pump();
    expect(t.preloadedIndex, 1);
    expect(deck.calls, containsAllInOrder(['preparePreload b', 'arm b']));
    expect(host.calls, contains('preloaded b'));

    expect(deck.bPoint!(), isTrue);
    expect(playlist.currentState.currentTrack!.item.id, 'b');
    // 映像の出どころは先読み側が開いた URI → 入れ替え → 波形
    expect(host.calls,
        containsAllInOrder(['source b preloaded', 'wave b', 'region b', 'switched b']));
    expect(deck.calls.last, isNot('swap'));
    expect(deck.calls, contains('swap'));
    expect(t.preloadedIndex, isNull);
    expect(deck.volumes.last, 80);
    await finish(tester);
  });

  testWidgets('先読みを捨てたら、後から終わった先読みは予約しない', (tester) async {
    unawaited(t.preloadNext());
    final gate = deck.preloadGate!;
    t.cancelPreload();
    gate.complete(null);
    await tester.pump();
    expect(t.preloadedIndex, isNull);
    expect(deck.calls.where((c) => c.startsWith('arm')), isEmpty);
    await finish(tester);
  });

  testWidgets('未準備のまま曲が終わったら頭から鳴らし直し、1 秒以内の二度目はしない', (tester) async {
    deck.trackEnd!();
    expect(deck.calls, containsAllInOrder(['seek 0', 'play', 'preparePreload b']));
    deck.calls.clear();
    deck.trackEnd!();
    expect(deck.calls.where((c) => c == 'play'), isEmpty);
    deck.preloadGate!.complete(null);
    await finish(tester);
  });

  testWidgets('リピートなしの最後の曲の B 点では止める', (tester) async {
    playlist.jumpTo(2);
    expect(deck.bPoint!(), isTrue);
    expect(deck.calls, contains('pauseAtEnd'));
    await finish(tester);
  });

  testWidgets('単曲リピートは B 点で進めない（AB ループのまま）', (tester) async {
    playlist
      ..cycleRepeatMode()
      ..cycleRepeatMode();
    expect(playlist.currentState.repeatMode, pl.RepeatMode.single);
    expect(deck.bPoint!(), isFalse);
    await finish(tester);
  });

  testWidgets('3 秒以内に続けて進めようとしたら、2 回目は待ってから 1 回だけ', (tester) async {
    t.autoAdvance(); // a → b（未先読みなので開き直し）
    expect(host.calls.where((c) => c == 'reload'), hasLength(1));
    t.autoAdvance();
    t.autoAdvance();
    expect(host.calls.where((c) => c == 'reload'), hasLength(1));
    clock = clock.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(host.calls.where((c) => c == 'reload'), hasLength(2));
    expect(playlist.currentState.currentTrack!.item.id, 'c');
    await finish(tester);
  });

  testWidgets('一覧で選んだ曲は先読みしてから、次の自動遷移でそこへ跳ぶ', (tester) async {
    await t.selectTrack(2);
    expect(deck.calls, contains('preparePreload c'));
    deck.preloadGate!.complete(null);
    await tester.pump();
    expect(t.preloadedIndex, 2);
    t.autoAdvance();
    expect(playlist.currentState.currentTrack!.item.id, 'c');
    expect(deck.calls, contains('swap'));
    await finish(tester);
  });

  testWidgets('前の曲（別の曲）は鳴っている側に開き直してから戻す', (tester) async {
    playlist.jumpTo(1);
    final done = t.manualPrev();
    expect(t.trackLoading, isTrue);
    // 開き終わるまでプレイリストは動かさない
    expect(playlist.currentState.currentTrack!.item.id, 'b');
    deck.activeGate!.complete();
    await done;
    expect(playlist.currentState.currentTrack!.item.id, 'a');
    expect(host.calls, containsAllInOrder(['source a -', 'region a', 'switched a']));
    expect(deck.calls, contains('play'));
    expect(t.trackLoading, isFalse);
    await finish(tester);
  });

  testWidgets('読込中の手動操作は受け付けない', (tester) async {
    unawaited(t.preloadNext());
    await t.manualNext();
    expect(playlist.currentState.currentTrack!.item.id, 'a');
    deck.preloadGate!.complete(null);
    await finish(tester);
  });

  testWidgets('重ね表示で前の曲に戻る: パーク中なら開き直さず、さっきの曲を次曲に予約し直す',
      (tester) async {
    playlist.jumpTo(1);
    deck.parked = 'a';
    t.replayPreviousFrom(const Duration(seconds: 70));
    expect(deck.calls, containsAllInOrder(['stepBack', 'arm b']));
    expect(playlist.currentState.currentTrack!.item.id, 'a');
    expect(t.preloadedIndex, 1);
    expect(host.calls, contains('source a active'));
    await finish(tester);
  });

  group('1 番だけモードのフェード', () {
    testWidgets('B 点の 3 秒前から 200ms ごとに下げる。ゾーンの外に戻れば元の音量', (tester) async {
      t.setBaseVolume(90);
      deck.volumes.clear();
      deck.pos = const Duration(seconds: 58);
      t.startFadeOutMonitor(60000);
      await tester.pump(const Duration(milliseconds: 600));
      expect(deck.volumes, hasLength(3));
      expect(deck.volumes.first, closeTo(90 * 14 / 15, 1e-9));
      expect(deck.volumes.last, lessThan(deck.volumes.first));
      deck.pos = const Duration(seconds: 10);
      await tester.pump(const Duration(milliseconds: 200));
      expect(deck.volumes.last, 90);
      await finish(tester);
    });

    testWidgets('クロスフェードがオンなら二重にかけない', (tester) async {
      deck.fadeOn = true;
      deck.pos = const Duration(seconds: 58);
      t.startFadeOutMonitor(60000);
      await tester.pump(const Duration(seconds: 1));
      expect(deck.volumes, isEmpty);
      await finish(tester);
    });

    testWidgets('フェード中は音量の上限だけ変える', (tester) async {
      deck.pos = const Duration(seconds: 58);
      t.startFadeOutMonitor(60000);
      await tester.pump(const Duration(milliseconds: 200));
      final n = deck.volumes.length;
      t.setBaseVolume(50);
      expect(deck.volumes, hasLength(n));
      expect(t.baseVolume, 50);
      await finish(tester);
    });
  });

  group('画面の無いとき（ミニプレイヤー中）', () {
    testWidgets('先読みしていない曲へ進むときは、画面を開き直さず鳴っている側に直接開く',
        (tester) async {
      host.canReload = false;
      t.autoAdvance();
      expect(host.calls, contains('reload'));
      expect(deck.calls, contains('prepareActive b'));
      deck.activeGate!.complete();
      await tester.pump();
      expect(playlist.currentState.currentTrack!.item.id, 'b');
      expect(host.calls, containsAllInOrder(['source b -', 'region b', 'switched b']));
      expect(deck.calls, contains('play'));
      await finish(tester);
    });

    testWidgets('持ち主がいなくなったら、B 点・曲の終わり・先読みの監視は何もしない',
        (tester) async {
      host.mounted = false;
      expect(deck.bPoint!(), isFalse);
      deck.trackEnd!();
      t.checkPreload();
      expect(deck.calls, isEmpty);
      expect(playlist.currentState.currentTrack!.item.id, 'a');
      await finish(tester);
    });
  });
}
