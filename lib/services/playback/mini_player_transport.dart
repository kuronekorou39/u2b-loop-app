import 'package:flutter/foundation.dart';

import '../../models/playlist_mode.dart' as pl;
import '../../models/playlist_track.dart';
import '../../providers/loop_provider.dart';
import '../../providers/mini_player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../../providers/playlist_player_provider.dart';
import 'pip_bridge.dart';

/// ミニプレイヤー中（再生画面を閉じた後）のプレイリスト進行。
///
/// 再生画面の dispose 後も動く必要があるので ref / mounted / BuildContext に依存せず、
/// 作るときに engine と各 Notifier を受け取る。遷移の機構（URL 解決・プリロード・
/// スロット入替・区間適用）は PlaylistEngine に集約してあり、再生画面側と同じ実装を通る。
/// ここに組み立てるのは「画面が無いときの振る舞い」だけ:
/// B 点・曲終了で次へ、未準備なら頭からやり直して止めない、通知・PiP のボタン
class MiniPlayerTransport {
  MiniPlayerTransport({
    required this.engine,
    required this.loop,
    required this.playlist,
    required this.mini,
  });

  final PlaylistEngine engine;
  final LoopNotifier loop;
  final PlaylistPlayerNotifier playlist;
  final MiniPlayerNotifier mini;

  int? _preloadedIdx;
  bool _isPreloading = false;
  DateTime? _lastReplayAt;

  /// ループのコールバックを握り、最初のプリロードを始める
  void start() {
    loop.onBPointReached = () {
      if (playlist.currentState.repeatMode == pl.RepeatMode.single) {
        return false;
      }
      final readiness = engine.readiness(preloadedIndex: _preloadedIdx);
      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        _advance(readiness);
        return true;
      }
      // 未準備 → AB ループ継続、裏でプリロードを確保
      if (readiness == AdvanceReadiness.notReady && !_isPreloading) {
        _preloadNext();
      }
      return false;
    };

    loop.onTrackEnd = () {
      final readiness = engine.readiness(preloadedIndex: _preloadedIdx);
      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        _advance(readiness);
      } else if (readiness == AdvanceReadiness.notReady) {
        _replayCurrent();
        if (!_isPreloading) _preloadNext();
      }
    };

    _preloadNext();
  }

  // --- 通知・PiP のボタンから ---

  Future<void> playPause() async {
    await engine.activePlayer.playOrPause();
    notifyPlayState();
  }

  void next() {
    final readiness = engine.readiness(preloadedIndex: _preloadedIdx);
    if (readiness == AdvanceReadiness.none) return;
    if (readiness == AdvanceReadiness.notReady) {
      if (!_isPreloading) _preloadNext();
      return;
    }
    _advance(readiness);
  }

  /// 前の曲。同一アイテムの別区間ならシーク、違う曲ならアクティブ側に直接読み込む
  Future<void> prev() async {
    final ps = playlist.currentState;
    final prevIdx = ps.peekPrevTrackIndex();
    if (prevIdx == null) return;
    final prevTrack = ps.tracks[prevIdx];
    final current = ps.currentTrack;
    if (current != null && prevTrack.isSameItem(current)) {
      if (!playlist.prev()) return;
      final track = playlist.currentState.currentTrack;
      if (track != null) _seekToTrack(track);
      return;
    }
    try {
      await engine.prepare(engine.activePlayer, prevTrack);
      playlist.jumpTo(prevIdx);
      final track = playlist.currentState.currentTrack;
      if (track == null) return;
      engine.activePlayer.play();
      engine.applyRegion(track);
      loop.setCurrentItem(track.item.id);
      mini.updateCurrentItem(track.item,
          trackIndex: playlist.currentState.currentTrackIndex);
      _preloadedIdx = null;
      _preloadNext();
    } catch (e) {
      debugPrint('[MiniPlayer] 前トラックの読み込みに失敗: $e');
    }
  }

  /// 再生状態を PiP と通知に伝える
  void notifyPlayState() => PipBridge.notifyPlayState(
        playing: engine.activePlayer.state.playing,
        item: mini.currentState.item,
      );

  // --- 内部 ---

  /// 次トラックをプリロードプレイヤーに読み込む
  Future<void> _preloadNext() async {
    if (_isPreloading || _preloadedIdx != null) return;
    final ps = playlist.currentState;
    final nextIdx = ps.peekNextTrackIndex();
    if (nextIdx == null) return;
    final nextTrack = ps.tracks[nextIdx];
    final current = ps.currentTrack;
    // 同一アイテムは遷移時のシークだけで済むためプリロード不要
    if (current != null && nextTrack.isSameItem(current)) return;

    _isPreloading = true;
    try {
      await engine.prepare(engine.preloadPlayer, nextTrack, downloadFirst: true);
      _preloadedIdx = nextIdx;
      engine.armCrossfade(nextTrack);
    } catch (e) {
      debugPrint('[MiniPlayer] プリロード失敗: $e');
    } finally {
      _isPreloading = false;
    }
  }

  void _advance(AdvanceReadiness readiness) {
    if (!playlist.next()) return;
    final track = playlist.currentState.currentTrack;
    if (track == null) return;
    if (readiness == AdvanceReadiness.sameItem) {
      _seekToTrack(track);
    } else {
      _swapToPreloaded(track);
    }
  }

  /// プリロード済みプレイヤーにスワップして再生開始
  void _swapToPreloaded(PlaylistTrack track) {
    _preloadedIdx = null;
    engine.swapSlots();
    engine.applyRegion(track);
    loop.setCurrentItem(track.item.id);
    mini.updateCurrentItem(track.item,
        trackIndex: playlist.currentState.currentTrackIndex);
    _preloadNext();
  }

  /// 同一アイテムの別区間にシーク
  void _seekToTrack(PlaylistTrack track) {
    if (track.startMs != null) {
      engine.activePlayer.seek(Duration(milliseconds: track.startMs!));
    }
    engine.applyRegion(track);
    mini.updateCurrentItem(track.item,
        trackIndex: playlist.currentState.currentTrackIndex);
  }

  /// 未準備のまま曲が終わった場合に、同じ曲を頭からやり直して再生を止めない。
  /// タイマーと completed の二重発火や極短トラックでの連続やり直しで
  /// フリーズしないよう 1 秒間は抑制する
  void _replayCurrent() {
    final now = DateTime.now();
    if (_lastReplayAt != null &&
        now.difference(_lastReplayAt!) <= const Duration(seconds: 1)) {
      return;
    }
    _lastReplayAt = now;
    try {
      engine.activePlayer
        ..seek(Duration.zero)
        ..play();
    } catch (_) {}
  }
}
