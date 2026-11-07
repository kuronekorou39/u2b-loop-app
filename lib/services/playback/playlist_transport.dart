import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_snack_bar.dart';
import '../../models/loop_item.dart';
import '../../models/loop_state.dart';
import '../../models/playlist_mode.dart' as pl;
import '../../models/playlist_track.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../../providers/playlist_player_provider.dart';

/// 進行役が使う再生の土台。本番は [EngineTransportDeck]（PlaylistEngine とプロバイダー）、
/// テストでは偽物に差し替える（media_kit の Player を作らずに遷移の手順を確かめるため）
abstract class TransportDeck {
  PlaylistPlayerNotifier get playlist;

  // --- エンジン ---
  AdvanceReadiness readiness({int? preloadedIndex, int? pendingJumpIndex});

  /// 次の曲を先読み側に開く（落としてから）。戻り値は波形の先読みに渡すマニフェスト
  Future<Object?> preparePreload(PlaylistTrack track,
      {required bool Function() isStale});

  /// 鳴っている側に曲を開き直す（前の曲・一覧から選んだ曲）
  Future<void> prepareActive(PlaylistTrack track,
      {required bool Function() isStale});
  void armCrossfade(PlaylistTrack next);
  void disarmCrossfade();
  bool get isCrossfading;
  void releaseParked();
  Future<void> pauseAtPlaylistEnd();
  String? get parkedItemId;
  bool stepBackToParked(Duration position);
  void swapSlots();
  Duration get crossfadeDuration;
  Duration? plannedCut();

  /// クロスフェードの設定がオン（エンジンが前の曲を下げるので 1 番だけのフェードはしない）
  bool get crossfadeOn;

  // --- 鳴っている側のプレイヤー ---
  Duration get position;
  Duration get duration;
  void setVolume(double volume);
  void seek(Duration position);
  void play();

  /// 実際に開いた URI（キャッシュのファイルかストリーム URL）
  String? get activeOpenedUri;

  // --- 先読み側のプレイヤー ---
  void stopPreload();
  String? get preloadOpenedUri;

  // --- ループ ---
  LoopState get loopState;
  set onBPointReached(bool Function()? callback);
  set onTrackEnd(void Function()? callback);
  void setCurrentItem(String? itemId);
}

/// 進行役から画面へ頼むこと（映像・波形・字幕・区間など、画面にしか無いもの）
abstract class TransportHost {
  bool get mounted;

  /// 最初の曲を開いている最中（一覧は見られるが選べない）
  bool get initialLoading;

  /// 進行の状態（読込中・先読み中の印）が変わった。描き直す
  void refresh();

  /// 先読みしていない曲へ自動で進む: 画面ごと開き直す
  void reloadCurrent();

  /// 曲の区間（AB・1 番だけ）を反映する。中で [PlaylistTransportController.setupCallbacks] を呼ぶ
  void loadTrackRegion(PlaylistTrack track);

  /// 映像の出どころを [track] に（[openedUri] は実際に開いた URI。無ければ曲の URI）
  void showSource(PlaylistTrack track, {String? openedUri});

  /// 波形を [track] のものに（手元に無ければ作る）
  void showWaveform(PlaylistTrack track);

  /// 先読みした曲に切り替わった（最初の曲を開いている途中でも読み込み中の表示を外す）
  void endLoading();

  /// 曲が切り替わった後の画面の仕上げ（字幕）
  void onTrackSwitched(PlaylistTrack track);

  /// 次の曲を先読みした（波形の先読みを始める）。[stillCurrent] が false になったら捨てる
  void onPreloaded(PlaylistTrack track, Object? manifest,
      {required bool Function() stillCurrent});

  /// 曲の大きさに合わせた音量（正規化がオフなら 100）
  double normalizedVolume(LoopItem item);
}

/// 再生画面のプレイリスト進行（先読み・自動遷移・手動の前後と選曲・1 番だけモードのフェード）。
///
/// 画面を閉じた後は [MiniPlayerTransport] が同じ役を引き継ぐ。遷移の機構（URL 解決・
/// プリロード・スロット入替・区間適用）は PlaylistEngine にあり、どちらも同じ実装を通る。
///
/// 思想:
/// - 再生が止まることは最悪の事態。どんな状態でも再生を継続する
/// - プリロードは最適化であって必須ではない
/// - 全てのトラック遷移は共通の後処理（[_afterTrackSwitch]）を通す
/// - ユーザー操作は [trackLoading] で排他制御。自動遷移はブロックしない
class PlaylistTransportController {
  PlaylistTransportController({
    required this.deck,
    required this.host,
    required this.isPlaylist,
    @visibleForTesting DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 今の時刻（テストでは時間送りに合わせた時計を渡す）
  final DateTime Function() _now;

  final TransportDeck deck;
  final TransportHost host;
  final bool isPlaylist;

  PlaylistPlayerNotifier get _playlist => deck.playlist;

  // --- 先読み ---

  /// 先読みして予約してある次の曲の番号（一覧の ✓）
  int? get preloadedIndex => _preloadedIndex;
  int? _preloadedIndex;

  /// 先読み・読み込み中の曲の番号（一覧のぐるぐる）
  int? get preloadingIndex => _preloadingIndex;
  int? _preloadingIndex;

  bool get isPreloading => _isPreloading;
  bool _isPreloading = false;

  /// 先読みの世代（古い先読みが後から終わっても使わない）
  int _generation = 0;
  int _failCount = 0;
  DateTime? _lastFailTime;
  Timer? _checkTimer;

  /// 手動選択: 次の自動遷移でここへ跳ぶ
  int? _pendingJumpIndex;

  /// 重ね表示で前の曲に戻って聴き直す位置
  Duration? _pendingReplaySeek;

  // --- 遷移の制御 ---

  /// 続けて開けなかった回数（[maxLoadErrors] で自動の送りを止める）
  int loadErrors = 0;
  static const maxLoadErrors = 3;
  DateTime? _lastAdvanceTime;
  bool _advanceRetryScheduled = false;
  DateTime? _lastTrackEndReplayAt;
  static const minAdvanceInterval = Duration(seconds: 3);

  /// 手動の操作で曲を読んでいる最中（前後のボタンを止める）
  bool get trackLoading => _trackLoading;
  bool _trackLoading = false;
  Timer? _loadingTimeoutTimer;
  static const loadingTimeout = Duration(seconds: 30);

  /// 読み込み中に操作したときの通知（出ている間は出し直さない）
  AppToastMessage? _loadingToast;

  // --- 1 番だけモードのフェード ---

  Timer? _fadeTimer; // フェードアウト監視 + 実行用
  Timer? _fadeInTimer; // フェードイン用（監視タイマーと独立）
  bool _isFading = false;
  bool _pendingFadeIn = false;

  /// 音量正規化の結果（正規化オフなら 100）。フェードイン/アウトはこの値を上限にする。
  /// 100 固定にするとフェード完了時に正規化した音量が上書きされてしまう
  double get baseVolume => _baseVolume;
  double _baseVolume = 100.0;

  static const _fadeOutMs = 3000;
  static const _fadeTick = Duration(milliseconds: 200);

  void dispose() {
    cancelFade();
    _checkTimer?.cancel();
    _checkTimer = null;
    _loadingTimeoutTimer?.cancel();
  }

  // =====================================================================
  // コールバック（B 点到達・曲の終わり）
  // =====================================================================

  AdvanceReadiness _readiness() => deck.readiness(
        preloadedIndex: _preloadedIndex,
        pendingJumpIndex: _pendingJumpIndex,
      );

  /// ループのコールバックを握る（プレイリストでなければ外す）
  void setupCallbacks() {
    if (!isPlaylist) {
      deck.onBPointReached = null;
      deck.onTrackEnd = null;
      return;
    }

    deck.onBPointReached = () {
      if (_playlist.currentState.repeatMode == pl.RepeatMode.single) {
        return false;
      }
      // 遷移可否の判定はミニプレイヤー側と共通（PlaylistEngine）
      final readiness = _readiness();
      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        autoAdvance();
        return true;
      }
      if (readiness == AdvanceReadiness.none) {
        // リピートなしで最後の曲: ループせずにそこで止める
        _finishPlaylist();
        return true;
      }
      // 未準備 → ABループ継続、プリロード確保
      if (!_isPreloading) preloadNext();
      return false;
    };

    deck.onTrackEnd = () {
      final readiness = _readiness();
      if (readiness == AdvanceReadiness.none) return;

      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        autoAdvance();
      } else {
        // 未準備 → 先頭に戻して再生継続。タイマーとcompletedの二重発火や
        // 極短トラックでの連続やり直しでフリーズしないよう1秒間は抑制。
        final now = _now();
        if (_lastTrackEndReplayAt == null ||
            now.difference(_lastTrackEndReplayAt!) >
                const Duration(seconds: 1)) {
          _lastTrackEndReplayAt = now;
          try {
            deck
              ..seek(Duration.zero)
              ..play();
          } catch (_) {}
        }
        if (!_isPreloading) preloadNext();
      }
    };
  }

  // =====================================================================
  // 自動遷移（B点到達 / 曲終了）
  // =====================================================================

  /// プレイリストの終わり（リピートなしで最後の曲の B 点）。
  /// 1 番だけモードの曲末フェードは戻して、次に再生を押したとき無音にならないように
  void _finishPlaylist() {
    cancelFade();
    try { deck.setVolume(_baseVolume); } catch (_) {}
    deck.pauseAtPlaylistEnd();
  }

  void autoAdvance() {
    if (loadErrors >= maxLoadErrors) return;

    // 高速遷移の抑制。リトライ予約は1本だけにする
    // （onTrackEndとB点到達が続けて発火すると、予約が積み上がって二重スキップになる）
    final now = _now();
    final sinceLast =
        _lastAdvanceTime == null ? null : now.difference(_lastAdvanceTime!);
    if (sinceLast != null && sinceLast < minAdvanceInterval) {
      if (!_advanceRetryScheduled) {
        _advanceRetryScheduled = true;
        Future.delayed(minAdvanceInterval - sinceLast, () {
          _advanceRetryScheduled = false;
          if (host.mounted) autoAdvance();
        });
      }
      return;
    }
    _lastAdvanceTime = now;

    final crossfading = deck.isCrossfading;
    final shouldFadeIn = _playlist.currentState.firstVerseMode &&
        _isFading &&
        !crossfading;
    cancelFade();
    // 交差中は旧プレイヤーの音量を戻さない（stop 直前に一瞬大きく鳴ってしまう）
    if (!crossfading) {
      try { deck.setVolume(_baseVolume); } catch (_) {}
    }

    final plState = _playlist.currentState;
    final oldTrack = plState.currentTrack;

    // 手動選択のキューがある場合はjumpTo、なければnext()
    final pendingJump = _pendingJumpIndex;
    _pendingJumpIndex = null;

    final nextIdx = pendingJump ?? plState.peekNextTrackIndex();
    final isPreloaded = _preloadedIndex != null && nextIdx == _preloadedIndex;

    bool changed;
    if (pendingJump != null) {
      _playlist.jumpTo(pendingJump);
      changed = true;
    } else {
      changed = _playlist.next();
    }
    if (!changed) {
      // 単曲リピート → 先頭にシーク
      final track = _playlist.currentState.currentTrack;
      if (track != null) {
        deck.seek(Duration(milliseconds: track.startMs ?? 0));
      }
      return;
    }

    final newTrack = _playlist.currentState.currentTrack;
    if (newTrack == null) return;

    if (oldTrack != null && newTrack.isSameItem(oldTrack)) {
      host.loadTrackRegion(newTrack);
      _afterTrackSwitch(newTrack, shouldFadeIn: shouldFadeIn);
    } else if (isPreloaded) {
      _swapToPreloaded(newTrack);
      host.loadTrackRegion(newTrack);
      _afterTrackSwitch(newTrack, shouldFadeIn: shouldFadeIn);
    } else {
      // 未プリロード → フルリロード（自動遷移なのでローディング画面OK）
      cancelPreload();
      _checkTimer?.cancel();
      _pendingFadeIn = shouldFadeIn;
      host.reloadCurrent();
    }
  }

  // =====================================================================
  // 手動操作: 次曲 / 前曲 / トラック選択
  // =====================================================================

  void _startLoadingTimeout() {
    _loadingTimeoutTimer?.cancel();
    _loadingTimeoutTimer = Timer(loadingTimeout, () {
      if (!host.mounted) return;
      cancelLoadingState();
      AppToast.instance.show(
        AppSnackBar.info('読込タイムアウト。操作可能です。'),
      );
    });
  }

  void cancelLoadingState() {
    _loadingTimeoutTimer?.cancel();
    cancelPreload();
    _trackLoading = false;
    _preloadingIndex = null;
    host.refresh();
  }

  /// 手動操作の共通ガード。ロード中なら拒否して true
  bool _guardManualOp() {
    if (_trackLoading || _isPreloading) {
      // 同じ通知が出ている間は出し直さない
      if (!identical(AppToast.instance.current.value, _loadingToast)) {
        _loadingToast = AppSnackBar.action('読込中...（タップでキャンセル）',
            label: 'キャンセル', onPressed: cancelLoadingState);
        AppToast.instance.show(_loadingToast!);
      }
      return true;
    }
    return false;
  }

  /// 手動: 次のトラックへ
  Future<void> manualNext() async {
    if (_guardManualOp()) return;
    deck.releaseParked();
    final ps = _playlist.currentState;
    if (!ps.hasNext) return;

    final readiness = _readiness();
    if (readiness == AdvanceReadiness.none) return;
    if (readiness == AdvanceReadiness.sameItem ||
        readiness == AdvanceReadiness.preloaded) {
      // 即遷移可能
      autoAdvance();
      return;
    }

    // プリロード待ち（スピナー表示、ローディング画面なし）
    final startTrackIdx = ps.currentTrackIndex;
    _trackLoading = true;
    host.refresh();
    _startLoadingTimeout();
    if (!_isPreloading) preloadNext();
    for (var i = 0; i < 300 && _preloadedIndex == null && host.mounted; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      // 自動遷移(onBPointReached)が先に実行された場合はキャンセル
      if (_playlist.currentState.currentTrackIndex != startTrackIdx) {
        _loadingTimeoutTimer?.cancel();
        _trackLoading = false;
        if (host.mounted) host.refresh();
        return;
      }
    }
    _loadingTimeoutTimer?.cancel();
    _trackLoading = false;
    if (host.mounted) host.refresh();
    // 自動遷移がまだ実行されていない場合のみ進む
    if (_preloadedIndex != null &&
        host.mounted &&
        _playlist.currentState.currentTrackIndex == startTrackIdx) {
      autoAdvance();
    }
  }

  /// 手動: 前のトラックへ。
  /// [manualNext] と対称な構造: peek してから判断し、状態変更はロード完了後
  Future<void> manualPrev() async {
    if (_guardManualOp()) return;
    deck.releaseParked();
    final ps = _playlist.currentState;
    if (!ps.hasPrev) return;

    final prevIdx = ps.peekPrevTrackIndex();
    if (prevIdx == null) return;
    final prevTrack = ps.tracks[prevIdx];
    final current = ps.currentTrack;
    final sameItem = current != null && prevTrack.isSameItem(current);

    if (sameItem) {
      // 同一アイテム → prev()で即移動+シーク（即座に完了）
      _playlist.prev();
      final track = _playlist.currentState.currentTrack;
      if (track == null) return;
      cancelFade();
      host.loadTrackRegion(track);
      _afterTrackSwitch(track);
      return;
    }

    // 異なるアイテム → 直接ロード（ロード完了後にprev()で状態変更）
    await _directLoadTrack(prevTrack, prevIdx);
  }

  /// 重ね表示で切り替わった後、前曲側（切替点より前）をタップしたとき。
  /// 前の曲に戻ってその位置から再生し、切り替わりをもう一度聴けるようにする
  /// （さっきまで鳴っていた曲を次曲として予約し直すので、クロスフェードが繰り返される。
  ///   交差の中に戻ったときは、エンジンが次曲をその分だけ進めた位置から重ねる）
  void replayPreviousFrom(Duration oldPos) {
    final ps = _playlist.currentState;
    if (!ps.hasPrev || _trackLoading || _isPreloading) return;
    final pos = oldPos < Duration.zero ? Duration.zero : oldPos;
    final prevIdx = ps.peekPrevTrackIndex();
    final nextIdx = ps.currentTrackIndex;
    // 前曲のプレイヤーがまだ生きている（パーク中）なら、開き直さずに戻る
    if (prevIdx != null &&
        nextIdx != null &&
        deck.parkedItemId == ps.tracks[prevIdx].item.id &&
        deck.stepBackToParked(pos)) {
      _afterStepBack(prevIdx, nextIdx);
      return;
    }
    // パークが切れていた（重ね表示が消えた後など）→ 開き直してでも戻る
    _pendingReplaySeek = pos;
    manualPrev();
  }

  /// パークした前曲に戻れたときの後始末（開き直しなし）。
  /// プレイリストを前曲に戻し、さっきまで鳴っていた曲を「プリロード済みの次曲」として
  /// 登録し直してクロスフェードを予約する（そのまま進めばもう一度つながる）
  void _afterStepBack(int prevIdx, int nextIdx) {
    _playlist.jumpTo(prevIdx);
    final ps = _playlist.currentState;
    final track = ps.currentTrack;
    if (track == null) return;
    final item = track.item;
    cancelFade();
    // 映像・波形・区間・コールバックを前曲に戻す
    host.showSource(track, openedUri: deck.activeOpenedUri);
    host.showWaveform(track);
    host.loadTrackRegion(track);
    setupCallbacks();
    deck.setCurrentItem(item.id);
    _baseVolume = host.normalizedVolume(item);
    try { deck.setVolume(_baseVolume); } catch (_) {}
    host.onTrackSwitched(track);
    // さっきまでの曲はプリロード側に載ったまま。次曲として予約し直す
    _generation++;
    _isPreloading = false;
    _preloadingIndex = null;
    _preloadedIndex = nextIdx;
    deck.armCrossfade(ps.tracks[nextIdx]);
    if (host.mounted) host.refresh();
  }

  /// 手動: トラック選択（一覧からタップ）
  Future<void> selectTrack(int trackIndex) async {
    // 最初の曲を開いている最中は一覧は見られるが選べない（同じプレイヤーを取り合うため）
    if (host.initialLoading) return;
    if (_guardManualOp()) return;
    final ps = _playlist.currentState;
    if (trackIndex == ps.currentTrackIndex) return;
    deck.releaseParked();

    final targetTrack = ps.tracks[trackIndex];
    final current = ps.currentTrack;

    // プリロード済み → 即スワップ
    if (_preloadedIndex == trackIndex) {
      _playlist.jumpTo(trackIndex);
      final track = _playlist.currentState.currentTrack!;
      _swapToPreloaded(track);
      host.loadTrackRegion(track);
      _afterTrackSwitch(track);
      return;
    }

    // 同一アイテム → シークのみ（即座に完了）
    if (current != null && targetTrack.isSameItem(current)) {
      _playlist.jumpTo(trackIndex);
      final track = _playlist.currentState.currentTrack!;
      host.loadTrackRegion(track);
      _afterTrackSwitch(track);
      return;
    }

    // 異なるアイテム → 次曲としてプリロード（自動遷移時にスワップ再生）
    cancelPreload();
    _pendingJumpIndex = trackIndex;
    preloadNext(trackIndex);
  }

  /// 直接ロード（前曲 / トラック選択で使用）
  Future<void> _directLoadTrack(PlaylistTrack track, [int? jumpToIndex]) async {
    cancelFade();
    cancelPreload();
    _startLoadingTimeout();
    _trackLoading = true;
    _preloadingIndex = jumpToIndex ?? _playlist.currentState.currentTrackIndex;
    host.refresh();

    try {
      // 開く手順（オフライン優先・メタデータ待ち・高音質の音声・速度）は
      // プリロードやミニプレイヤーの前曲と同じ PlaylistEngine.prepare を通す
      await deck
          .prepareActive(track, isStale: () => !host.mounted)
          .timeout(const Duration(seconds: 60));
      if (!host.mounted) return;
      host.showSource(track);

      if (jumpToIndex != null) _playlist.jumpTo(jumpToIndex);
      host.loadTrackRegion(_playlist.currentState.currentTrack ?? track);
      deck.play();
      _afterTrackSwitch(_playlist.currentState.currentTrack ?? track);
    } catch (_) {
      // 失敗は無視（次のタップで再試行される）
    } finally {
      // ロードが終わったらタイムアウト監視も止める
      // （残すと30秒後に cancelLoadingState が走り、次曲プリロードを誤って破棄する）
      _loadingTimeoutTimer?.cancel();
      _trackLoading = false;
      _preloadingIndex = null;
      if (host.mounted) host.refresh();
    }
  }

  /// トラック切替後の共通の後処理
  void _afterTrackSwitch(PlaylistTrack track, {bool shouldFadeIn = false}) {
    _preloadedIndex = null;
    _pendingJumpIndex = null;
    setupCallbacks();
    deck.setCurrentItem(track.item.id);
    startPreloadMonitor();
    // 新しい曲の大きさに合わせた音量を上限にする（下で setVolume / フェードインに使う）
    _baseVolume = host.normalizedVolume(track.item);
    if (shouldFadeIn) {
      _startFadeIn();
    } else {
      // スワップ後のボリュームストリーム同期
      // （旧プレイヤーのフェードアウト値が残らないよう新プレイヤーに明示設定）
      try { deck.setVolume(_baseVolume); } catch (_) {}
    }
    // ミックスビューから前曲に戻って聴き直す指定があれば、その位置へ
    final replay = _pendingReplaySeek;
    _pendingReplaySeek = null;
    if (replay != null) {
      try { deck.seek(replay); } catch (_) {}
    }
    loadErrors = 0;
    host.onTrackSwitched(track);
    // 2秒後に次曲プリロード開始（再生を安定させてから）
    Future.delayed(const Duration(seconds: 2), () {
      if (host.mounted && !_isPreloading && _preloadedIndex == null) {
        preloadNext();
      }
    });
  }

  /// 画面が曲を開き終えた（最初の曲・開き直し）。フェードイン・先読みの開始
  void onItemLoaded() {
    if (_trackLoading) {
      _trackLoading = false;
      host.refresh();
    }
    loadErrors = 0;
    // フルリロードパスでのフェードイン（自動遷移から来た場合）
    if (_pendingFadeIn) {
      _pendingFadeIn = false;
      _startFadeIn();
    }
    // 先読みの監視（2 秒後に開始、再生を安定させてから）
    if (isPlaylist) {
      Future.delayed(const Duration(seconds: 2), () {
        if (host.mounted && !_isPreloading && _preloadedIndex == null) {
          startPreloadMonitor();
          preloadNext();
        }
      });
    }
  }

  /// ミニプレイヤーから戻ったとき: 進行役が予約した次曲（[index]）をそのまま引き継ぐ
  void adoptPreloaded(int index) => _preloadedIndex = index;

  // --- シャッフル・リピート・一覧の変更 ---

  void onShuffleToggled() {
    _pendingJumpIndex = null;
    cancelPreload();
    preloadNext();
  }

  /// リピートを変えた: 予約済みの次曲が変わったときだけ捨てる（読み直しは定期チェックで）
  void onRepeatChanged() {
    final nextIdx = _playlist.currentState.peekNextTrackIndex();
    if (_preloadedIndex != null && _preloadedIndex != nextIdx) {
      cancelPreload();
    }
  }

  // =====================================================================
  // 1 番だけモードのフェード
  // =====================================================================

  /// 音量の上限を変える（音量正規化）。フェード中は上限だけ
  void setBaseVolume(double volume) {
    _baseVolume = volume;
    if (_isFading) return;
    try { deck.setVolume(_baseVolume); } catch (_) {}
  }

  /// フェードアウトの監視だけ止める（フェードインは中断しない）
  void cancelFadeOut() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _isFading = false;
  }

  /// B 点の 3 秒前からフェードアウトを開始する監視。
  /// AB ループで A 点に戻った場合も自動的にリセットして次パスで再フェードする
  void startFadeOutMonitor(int cutMs) {
    cancelFade();
    // クロスフェードが有効なら PlaylistEngine 側が旧曲を下げるので、二重にかけない
    if (deck.crossfadeOn) return;
    final fadeStartMs = cutMs - _fadeOutMs;
    if (fadeStartMs <= 0) return;

    var fadeStep = 0;
    const fadeSteps = 15; // 200ms × 15 = 3秒

    _fadeTimer = Timer.periodic(_fadeTick, (_) {
      if (!host.mounted) {
        cancelFade();
        return;
      }
      final posMs = deck.position.inMilliseconds;

      if (posMs < fadeStartMs) {
        // フェードゾーン外（A点にシークされた等）→ 状態リセット
        if (_isFading) {
          _isFading = false;
          fadeStep = 0;
          try { deck.setVolume(_baseVolume); } catch (_) {}
        }
        return;
      }

      // フェードゾーン内
      if (!_isFading) {
        _isFading = true;
        fadeStep = 0;
      }
      fadeStep++;
      if (fadeStep <= fadeSteps) {
        final volume = (1.0 - fadeStep / fadeSteps).clamp(0.0, 1.0);
        try { deck.setVolume(volume * _baseVolume); } catch (_) {}
      }
    });
  }

  /// フェードイン（次曲開始時に呼ぶ）。フェードアウト監視とは独立して動く
  void _startFadeIn() {
    _fadeInTimer?.cancel();
    const steps = 5; // 200ms × 5 = 1秒
    var step = 0;
    deck.setVolume(0);
    _fadeInTimer = Timer.periodic(_fadeTick, (_) {
      step++;
      final volume = (step / steps).clamp(0.0, 1.0);
      try { deck.setVolume(volume * _baseVolume); } catch (_) {}
      if (step >= steps) {
        _fadeInTimer?.cancel();
        _fadeInTimer = null;
      }
    });
  }

  void cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
    _isFading = false;
  }

  // =====================================================================
  // 先読み
  // =====================================================================

  void cancelPreload() {
    deck.disarmCrossfade();
    _generation++;
    _preloadedIndex = null;
    _preloadingIndex = null;
    _isPreloading = false;
    // プリロードプレイヤーの実行中の操作を確実に中断
    // （パーク中の前曲は別のスロットにいるので止まらない）
    try { deck.stopPreload(); } catch (_) {}
  }

  /// [keepPreload] なら、今ある先読みと予約（[preloadedIndex]）を捨てずに監視だけ始める
  /// （ミニプレイヤーから戻るとき）
  void startPreloadMonitor({bool keepPreload = false}) {
    _checkTimer?.cancel();
    if (!keepPreload) cancelPreload();
    _failCount = 0;

    if (!isPlaylist) return;

    _checkTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => checkPreload(),
    );
  }

  /// 先読みを始める時刻か見る（定期チェック）
  @visibleForTesting
  void checkPreload() {
    if (!host.mounted || !isPlaylist || host.initialLoading) return;
    if (_isPreloading || _preloadedIndex != null) return;

    // 連続失敗時はバックオフ（失敗数 × 10秒）、上限5回で停止
    if (_failCount > 0) {
      if (_failCount >= 5) return;
      final backoff = Duration(seconds: _failCount * 10);
      if (_lastFailTime != null &&
          _now().difference(_lastFailTime!) < backoff) {
        return;
      }
    }

    final position = deck.position;
    final duration = deck.duration;
    if (duration <= Duration.zero) return;
    final item = _playlist.currentState.currentTrack?.item;
    if (item == null) return;

    // 1番だけモードではB点を終了地点として使う
    final loop = deck.loopState;
    final isFirstVerse =
        _playlist.currentState.firstVerseMode && loop.enabled && loop.hasB;
    var endPoint = isFirstVerse ? loop.pointB! : duration;
    // アウトロ点・選んだ出口で早めに切るなら、そこから逆算する（曲末からだと交差に間に合わない）
    final cut = isFirstVerse ? null : deck.plannedCut();
    if (cut != null && cut > Duration.zero && cut < endPoint) endPoint = cut;

    // 先読みを始める残り時間の式はエンジンと共通
    final lead = PlaylistEngine.preloadLead(
      item: item,
      endPoint: endPoint,
      firstVerse: isFirstVerse,
      fade: deck.crossfadeDuration,
    );
    if (endPoint - position <= lead) preloadNext();
  }

  /// 次の曲（[overrideIndex] があればその曲）を先読みして予約する
  Future<void> preloadNext([int? overrideIndex]) async {
    if (_isPreloading) return;
    _isPreloading = true;
    final gen = ++_generation; // この世代のプリロード

    bool isStale() => !host.mounted || gen != _generation;

    try {
      final plState = _playlist.currentState;
      final int? nextIdx;
      if (overrideIndex != null) {
        nextIdx = overrideIndex;
        _preloadedIndex = null;
      } else {
        nextIdx = plState.peekNextTrackIndex();
      }
      if (nextIdx == null) {
        _isPreloading = false;
        return;
      }

      _preloadingIndex = nextIdx;
      if (host.mounted) host.refresh();

      final nextTrack = plState.tracks[nextIdx];

      // 同じ曲 → 遷移時のシークだけで済むので先読みしない
      final currentTrack = plState.currentTrack;
      if (currentTrack != null && nextTrack.isSameItem(currentTrack)) {
        _isPreloading = false;
        return;
      }

      // ロード機構（キャッシュ優先・メタデータ待ち・シーク・速度設定）は
      // PlaylistEngine に集約してあり、ミニプレイヤー側と同じ実装を通る。
      // manifest は波形の先行生成に再利用する（キャッシュ再生時は null）
      final manifest = await deck.preparePreload(nextTrack, isStale: isStale);

      if (isStale()) return;
      _preloadedIndex = nextIdx;
      _failCount = 0;
      deck.armCrossfade(nextTrack);
      if (host.mounted) host.refresh();

      // 波形の先行読み込み（並行）
      host.onPreloaded(nextTrack, manifest,
          stillCurrent: () => gen == _generation);
    } catch (e) {
      debugPrint('[Preload] 失敗: $e');
      if (gen == _generation) {
        _preloadedIndex = null;
        _failCount++;
        _lastFailTime = _now();
      }
    } finally {
      if (gen == _generation) {
        _isPreloading = false;
        _preloadingIndex = null;
      }
      if (host.mounted) host.refresh();
    }
  }

  void _swapToPreloaded(PlaylistTrack newTrack) {
    // プリロード状態をクリア（プレイヤーはstopしない — これからスワップして使う）
    _generation++;
    _preloadedIndex = null;
    _preloadingIndex = null;
    _isPreloading = false;

    // 動画ソースを先に更新しておく（スワップ前にUIが参照できるように）。
    // URI はプリロード側が実際に開いたもの（キャッシュのファイルかストリーム URL）。
    // 曲の登録 URL（YouTube のページ）を入れると書き出し・波形が使えない
    host.showSource(newTrack, openedUri: deck.preloadOpenedUri);

    // スロット入替・旧プレイヤーの停止・新プレイヤーの再生開始は
    // PlaylistEngine に集約（ミニプレイヤー側と同じ実装を通る）
    deck.swapSlots();

    // 再生カウント: トラック切替
    deck.setCurrentItem(newTrack.item.id);
    host.showWaveform(newTrack);
    host.endLoading();
  }
}

/// 本番の [TransportDeck]: PlaylistEngine とプロバイダーを毎回読みに行く
/// （鳴っている側・先読み側のプレイヤーはスロットの入れ替えで変わる）
class EngineTransportDeck implements TransportDeck {
  EngineTransportDeck(this._ref);

  final WidgetRef _ref;

  PlaylistEngine get _engine => _ref.read(playlistEngineProvider);
  LoopNotifier get _loop => _ref.read(loopProvider.notifier);

  @override
  PlaylistPlayerNotifier get playlist =>
      _ref.read(playlistPlayerProvider.notifier);

  @override
  AdvanceReadiness readiness({int? preloadedIndex, int? pendingJumpIndex}) =>
      _engine.readiness(
          preloadedIndex: preloadedIndex, pendingJumpIndex: pendingJumpIndex);

  @override
  Future<Object?> preparePreload(PlaylistTrack track,
          {required bool Function() isStale}) =>
      _engine.prepare(_ref.read(preloadPlayerProvider), track,
          isStale: isStale, downloadFirst: true);

  @override
  Future<void> prepareActive(PlaylistTrack track,
          {required bool Function() isStale}) =>
      _engine.prepare(_ref.read(playerProvider), track, isStale: isStale);

  @override
  void armCrossfade(PlaylistTrack next) => _engine.armCrossfade(next);
  @override
  void disarmCrossfade() => _engine.disarmCrossfade();
  @override
  bool get isCrossfading => _engine.isCrossfading;
  @override
  void releaseParked() => _engine.releaseParked();
  @override
  Future<void> pauseAtPlaylistEnd() => _engine.pauseAtPlaylistEnd();
  @override
  String? get parkedItemId => _engine.parkedItemId;
  @override
  bool stepBackToParked(Duration position) =>
      _engine.stepBackToParked(position);
  @override
  void swapSlots() => _engine.swapSlots();
  @override
  Duration get crossfadeDuration => _engine.crossfadeDuration;
  @override
  Duration? plannedCut() => _engine.plannedCut();
  @override
  bool get crossfadeOn => _ref.read(crossfadeProvider) > 0;

  @override
  Duration get position => _ref.read(playerProvider).state.position;
  @override
  Duration get duration => _ref.read(playerProvider).state.duration;
  @override
  void setVolume(double volume) => _ref.read(playerProvider).setVolume(volume);
  @override
  void seek(Duration position) => _ref.read(playerProvider).seek(position);
  @override
  void play() => _ref.read(playerProvider).play();
  @override
  String? get activeOpenedUri =>
      _ref.read(playerProvider).state.playlist.medias.firstOrNull?.uri;

  @override
  void stopPreload() => _ref.read(preloadPlayerProvider).stop();
  @override
  String? get preloadOpenedUri =>
      _ref.read(preloadPlayerProvider).state.playlist.medias.firstOrNull?.uri;

  @override
  LoopState get loopState => _ref.read(loopProvider);
  @override
  set onBPointReached(bool Function()? callback) =>
      _loop.onBPointReached = callback;
  @override
  set onTrackEnd(void Function()? callback) => _loop.onTrackEnd = callback;
  @override
  void setCurrentItem(String? itemId) => _loop.setCurrentItem(itemId);
}
