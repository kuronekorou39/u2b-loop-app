import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../app.dart';
import '../core/audio/energy_profile.dart';
import '../core/audio/loudness.dart';
import '../core/audio/mix_point_detector.dart';
import '../core/constants.dart';
import '../core/loop/region_edit_controller.dart';
import '../core/utils/app_errors.dart';
import '../core/utils/verse_detector.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/playlist_mode.dart' as pl;
import '../models/playlist_track.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_engine.dart';
import '../providers/playlist_player_provider.dart';
import '../services/export_runner.dart';
import '../services/export_source.dart';
import '../services/playback/load_progress.dart';
import '../services/playback/mini_player_transport.dart';
import '../services/playback/pip_bridge.dart';
import '../services/playback/player_loader.dart';
import '../services/playback/subtitle_loader.dart';
import '../services/playback/waveform_loader.dart';
import '../providers/subtitle_provider.dart';
import '../services/audio_analysis_service.dart';
import '../services/waveform_cache.dart';
import '../services/cache_service.dart';
import '../services/waveform_service.dart';
import '../widgets/lyrics_overlay.dart';
import '../widgets/item_tag_sheet.dart';
import '../widgets/loop/ab_edit_controls.dart';
import '../widgets/loop/ab_edit_panel.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/loop/region_panel.dart';
import '../widgets/player/dj_mix_sheet.dart';
import '../widgets/player/fullscreen_player_view.dart';
import '../widgets/player/now_playing_header.dart';
import '../widgets/player/player_wide_top_bar.dart';
import '../widgets/player/track_list.dart';
import '../widgets/player/player_more_sheet.dart';
import '../widgets/player/player_shell.dart';
import '../widgets/player/player_status_views.dart';
import '../widgets/player/playlist_bottom_bar.dart';
import '../widgets/player/playlist_seek_area.dart';
import '../widgets/player/single_more_sheet.dart';
import '../widgets/player/single_player_bar.dart';
import '../widgets/player/subtitle_language_sheet.dart';
import '../widgets/player/subtitle_toggle_button.dart';
import '../widgets/player/transition_stage.dart';
import '../widgets/player/video_player_widget.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/storage/app_boxes.dart';
import '../core/utils/id_generator.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';

/// 汎用プレーヤー画面。単体再生・プレイリスト再生・PiP対応。
/// ミニプレイヤー中に通知・PiPから届くメディア操作の受け口。
/// PlayerScreen の dispose 後に呼ばれるため、ref や mounted に依存しないこと。
class PlayerScreen extends ConsumerStatefulWidget {
  final LoopItem item;
  final List<LoopItem>? playlistItems;
  final int initialIndex;
  final Map<String, List<String>>? regionSelections;
  final Set<String>? disabledItemIds;
  final String? playlistName;
  final String? playlistId;

  const PlayerScreen({
    super.key,
    required this.item,
    this.playlistItems,
    this.initialIndex = 0,
    this.regionSelections,
    this.disabledItemIds,
    this.playlistName,
    this.playlistId,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {

  bool _loading = true;
  String? _loadError;

  /// 読み込みの進捗・曲を開く手順・波形は AB 設定画面と同じ部品。
  /// プレイリストの遷移（プリロード側）だけは PlaylistEngine.prepare
  final _progress = LoadProgress();
  late final _loader =
      PlayerLoader(ref, progress: _progress, isMounted: () => mounted);
  late final _waveform = WaveformLoader(ref, isMounted: () => mounted);

  int _activeRegionIdx = -1;
  bool _compactSeekbar = false;

  // 全画面（ボタンで入る。横画面のレイアウトとは別）
  bool _isFullscreen = false;
  bool _showFullscreenOverlay = true;
  bool _showRightDrawer = false;
  Timer? _overlayHideTimer;
  bool _hideVideo = false;

  /// 中段パネル（プレイリスト: トラック一覧、単体: AB 区間）を開いているか。
  /// ふだんは閉じている
  bool _panelOpen = false;
  final _trackListController = ScrollController();

  /// AB 編集中。微調整の刻みは loopProvider の adjustStep（AB 設定画面と同じ値）
  bool _editMode = false;
  int? _preloadingTargetIndex;

  // Preload state
  int? _preloadedTrackIndex;
  int? _pendingJumpIndex; // 手動選択時: 次の自動遷移でjumpToするインデックス
  Duration? _pendingReplaySeek; // ミックスビューで前曲に戻って聴き直す位置
  bool _isPreloading = false;
  Timer? _preloadCheckTimer;
  int _preloadGeneration = 0; // レース条件防止用の世代カウンタ
  int _preloadFailCount = 0; // プリロード連続失敗カウンタ
  DateTime? _lastPreloadFailTime;

  // Playlist error control
  int _consecutiveLoadErrors = 0;
  DateTime? _lastAdvanceTime;
  bool _advanceRetryScheduled = false; // 遅延リトライの多重予約防止
  DateTime? _lastTrackEndReplayAt; // onTrackEnd未準備時の再生やり直しの連続発火抑制
  static const _maxConsecutiveErrors = 3;
  Timer? _loadingTimeoutTimer;
  static const _minAdvanceInterval = Duration(seconds: 3);

  // First verse fade
  Timer? _fadeTimer;     // フェードアウト監視 + 実行用
  Timer? _fadeInTimer;   // フェードイン用（監視タイマーと独立）
  bool _isFading = false;
  bool _pendingFadeIn = false;

  /// 音量正規化の結果（正規化OFFなら100。[_applyVolumeNorm]）。
  /// フェードイン/アウトはこの値を上限にする。100固定にすると
  /// フェード完了時に正規化した音量が上書きされてしまう。
  double _baseVolume = 100.0;

  bool _trackLoading = false;
  bool _loadingSnackShowing = false;

  // Waveform cache: itemId → waveform data
  final Map<String, List<double>> _waveformCache = {};

  LoopItem get _currentItem {
    if (_isPlaylist) {
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track != null) return track.item;
    }
    return widget.item;
  }

  bool get _isPlaylist => widget.playlistItems != null;

  bool _wasPlayingBeforePause = false;

  /// ミニプレイヤー中（この画面の dispose 後）のプレイリスト進行と、通知・PiP のボタン。
  /// ref/mounted に依存しないので dispose 後も動く
  MiniPlayerTransport? _miniTransport;

  /// 字幕の用意（オフライン SRT / YouTube 取得 / 言語の選び直し）
  late final _subtitles = SubtitleLoader(ref, isMounted: () => mounted);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playerScreenActive = true;

    // 画面表示中のネイティブからの呼び出し（PiP・通知のボタン、出力先、ヘッドホン抜き）
    PipBridge.listen(PipHandlers(
      onPiPChanged: (inPiP) =>
          ref.read(pipModeProvider.notifier).state = inPiP,
      onAction: (action) async {
        switch (action) {
          case PipAction.playPause:
            final player = ref.read(playerProvider);
            await player.playOrPause();
            // ユーザーの明示操作なので、復帰時の自動再開判定も追従させる
            _wasPlayingBeforePause = player.state.playing;
            _updatePiPPlayState();
          case PipAction.next:
            if (_isPlaylist) _manualNext();
          case PipAction.prev:
            if (_isPlaylist) _manualPrev();
        }
      },
      onAudioDeviceChanged: (device) =>
          ref.read(audioDeviceProvider.notifier).state = device,
      onAudioNoisy: () async {
        // ヘッドホン抜き/Bluetooth切断 → 一時停止
        final player = ref.read(playerProvider);
        if (player.state.playing) await player.pause();
        // 復帰時にスピーカーから鳴り出さないよう自動再開を無効化
        _wasPlayingBeforePause = false;
      },
      getPlayState: () => ref.read(playerProvider).state.playing,
    ));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ミニプレイヤーからの復帰判定
      final miniState = ref.read(miniPlayerProvider);
      final isSameContext = miniState.item != null
          && miniState.item!.id == _currentItem.id
          && miniState.playlistId == widget.playlistId;

      if (isSameContext) {
        // 同一コンテキスト: ロードスキップ、再生状態を復元
        final wasPlaying = miniState.wasPlaying;
        ref.read(miniPlayerProvider.notifier).clearRestoreInfo();
        // ミニプレイヤーの進行役から画面が引き継ぐ（予約済みのクロスフェードは使える）
        ref.read(playlistEngineProvider).endSession(keepCrossfade: true);
        ref.read(loopProvider.notifier).setCurrentItem(_currentItem.id);
        _setupPlaylistCallbacks();
        PipBridge.setAutoPiP(
            enabled: true, isPlaylist: _isPlaylist, item: _currentItem);
        _updatePiPPlayState();
        _startPreloadMonitor();
        // iOS: トランジション中にmpvが自動pauseするため、遷移前の状態に基づいて復元
        if (wasPlaying) {
          ref.read(playerProvider).play();
        }
        setState(() {
          _loading = false;
          _loadError = null;
        });
        return;
      }

      // ミニプレイヤーが再生中: 停止してから新規ロード
      if (miniState.item != null || miniState.active) {
        ref.read(miniPlayerProvider.notifier).deactivate();
        try {
          ref.read(playerAProvider).stop();
          ref.read(playerBProvider).stop();
        } catch (_) {}
      }

      // 前のプレイリスト（ミニプレイヤーで続いていた分も）を打ち切る
      final engine = ref.read(playlistEngineProvider);
      _isPlaylist ? engine.endSession() : engine.endPlaylist();
      ref.read(activeSlotProvider.notifier).state = ActiveSlot.a;
      ref.read(videoSourceProvider.notifier).state = null;
      ref.read(loopProvider.notifier).reset();
      ref.read(waveformDataProvider.notifier).state = null;
      ref.read(waveformLoadingProvider.notifier).state = false;
      ref.read(waveformErrorProvider.notifier).state = null;

      // Initialize playlist provider if in playlist mode
      if (_isPlaylist) {
        ref.read(playlistPlayerProvider.notifier).loadPlaylist(
              widget.playlistItems!,
              initialItemIndex: widget.initialIndex,
              regionSelections: widget.regionSelections,
              disabledItemIds: widget.disabledItemIds,
            );
        // デフォルトシャッフル適用
        if (widget.playlistId != null) {
          final plBox = AppBoxes.playlists;
          final pl = plBox.get(widget.playlistId);
          if (pl != null && pl.defaultShuffle) {
            ref.read(playlistPlayerProvider.notifier).toggleShuffle();
          }
        }
      }

      _loadItem();
      // 自動PiPを有効化 + 現在の再生状態を送信
      PipBridge.setAutoPiP(
          enabled: true, isPlaylist: _isPlaylist, item: _currentItem);
      _updatePiPPlayState();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // 画面オフ/バックグラウンド: 再生中だったら記録
      if (ref.read(playerProvider).state.playing) {
        _wasPlayingBeforePause = true;
      }
      // 画面オフでもすぐに再生再開（Foreground Serviceでプロセス保持）
      if (_wasPlayingBeforePause) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _wasPlayingBeforePause &&
              !ref.read(playerProvider).state.playing) {
            ref.read(playerProvider).play();
          }
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      // フォアグラウンド復帰: まだ停止していたら再開
      if (_wasPlayingBeforePause && !ref.read(playerProvider).state.playing) {
        ref.read(playerProvider).play();
      }
      _wasPlayingBeforePause = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playerScreenActive = false;
    _progress.dispose();
    _overlayHideTimer?.cancel();
    _loadingTimeoutTimer?.cancel();
    _trackListController.dispose();
    _cancelFade();
    // 全画面モード解除（バックジェスチャ等で全画面のまま離脱しても向きを戻す）
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _preloadCheckTimer?.cancel();

    // ミニプレイヤー有効時は再生状態を温存
    final miniActive = ref.read(miniPlayerProvider).active;

    // 自動PiP: ミニプレイヤー有効時は維持（PiP突入後にPlayerScreenに遷移する）
    if (!miniActive) {
      PipBridge.setAutoPiP(enabled: false);
      try {
        ref.read(loopProvider.notifier).setCurrentItem(null);
        ref.read(playerAProvider).stop();
        ref.read(playerBProvider).stop();
        ref.read(loopProvider.notifier).onBPointReached = null;
        ref.read(loopProvider.notifier).onTrackEnd = null;
        if (_isPlaylist) ref.read(playlistPlayerProvider.notifier).clear();
        ref.read(playlistEngineProvider).endSession();
        ref.read(activeSlotProvider.notifier).state = ActiveSlot.a;
      } catch (_) {}
    }

    // dispose後もプロバイダーコンテナは生きているので、コントローラを先に捕まえておく
    final pipMode = ref.read(pipModeProvider.notifier);

    if (miniActive) {
      // ミニプレイヤー中のハンドラ。
      // PiP表示はアプリのルートが pipModeProvider を見て切り替えるので、
      // ここでは状態を伝えるだけでよい（以前はPiP突入後にPlayerScreenを
      // pushして映像に差し替えようとしていたが、PiPに入った後では手遅れで、
      // 一覧画面がそのままPiPに映っていた）。
      // 単体再生（プレイリストでない）では _miniTransport が無いので、
      // 再生/一時停止だけは直接プレイヤーを叩く
      final transport = _miniTransport;
      final engine = ref.read(playlistEngineProvider);
      final miniNotifier = ref.read(miniPlayerProvider.notifier);
      final audioDevice = ref.read(audioDeviceProvider.notifier);
      void notify() => PipBridge.notifyPlayState(
            playing: engine.activePlayer.state.playing,
            item: miniNotifier.currentState.item,
          );
      PipBridge.listen(PipHandlers(
        onPiPChanged: (inPiP) => pipMode.state = inPiP,
        onAction: (action) async {
          switch (action) {
            case PipAction.playPause:
              if (transport != null) {
                await transport.playPause();
              } else {
                await engine.activePlayer.playOrPause();
                notify();
              }
            case PipAction.next:
              transport?.next();
            case PipAction.prev:
              await transport?.prev();
          }
        },
        onAudioDeviceChanged: (device) => audioDevice.state = device,
        onAudioNoisy: () async {
          // ヘッドホン抜き/Bluetooth切断 → 一時停止
          final player = engine.activePlayer;
          if (player.state.playing) await player.pause();
          notify();
        },
        getPlayState: () => engine.activePlayer.state.playing,
      ));
    } else {
      pipMode.state = false;
      PipBridge.stopListening();
    }
    _waveform.dispose();
    // ミニプレイヤー非アクティブならバックグラウンド再生停止
    if (!miniActive) {
      WakelockPlus.disable();
      PipBridge.stopPlaybackService();
    }
    super.dispose();
  }

  // =====================================================================
  // プレイリスト再生制御（統一設計）
  //
  // 思想:
  // - 再生が止まることは最悪の事態。どんな状態でも再生を継続する。
  // - プリロードは最適化であって必須ではない。
  // - 全てのトラック遷移は共通の後処理（_afterTrackSwitch）を通す。
  // - ユーザー操作は _trackLoading で排他制御。自動遷移はブロックしない。
  // =====================================================================

  /// 現在のプリロード状況で次トラックへ進めるかを判定する
  /// （判定ロジックはミニプレイヤー側と共通の PlaylistEngine に置いてある）
  AdvanceReadiness _readiness() => ref.read(playlistEngineProvider).readiness(
        preloadedIndex: _preloadedTrackIndex,
        pendingJumpIndex: _pendingJumpIndex,
      );

  /// コールバック設定（PlayerScreen表示中 + ミニプレイヤー中 共通）
  void _setupPlaylistCallbacks() {
    final loopNotifier = ref.read(loopProvider.notifier);
    if (!_isPlaylist) {
      loopNotifier.onBPointReached = null;
      loopNotifier.onTrackEnd = null;
      return;
    }

    loopNotifier.onBPointReached = () {
      if (ref.read(playlistPlayerProvider).repeatMode == pl.RepeatMode.single) {
        return false;
      }
      // 遷移可否の判定はミニプレイヤー側と共通（PlaylistEngine）
      final readiness = _readiness();
      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        _autoAdvance();
        return true;
      }
      if (readiness == AdvanceReadiness.none) return false;
      // 未準備 → ABループ継続、プリロード確保
      if (!_isPreloading) _preloadNextTrack();
      return false;
    };

    loopNotifier.onTrackEnd = () {
      final readiness = _readiness();
      if (readiness == AdvanceReadiness.none) return;

      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        _autoAdvance();
      } else {
        // 未準備 → 先頭に戻して再生継続。タイマーとcompletedの二重発火や
        // 極短トラックでの連続やり直しでフリーズしないよう1秒間は抑制。
        final now = DateTime.now();
        if (_lastTrackEndReplayAt == null ||
            now.difference(_lastTrackEndReplayAt!) >
                const Duration(seconds: 1)) {
          _lastTrackEndReplayAt = now;
          try {
            ref.read(playerProvider)
              ..seek(Duration.zero)
              ..play();
          } catch (_) {}
        }
        if (!_isPreloading) _preloadNextTrack();
      }
    };
  }

  // ----- 自動遷移（B点到達 / 曲終了） -----

  void _autoAdvance() {
    if (_consecutiveLoadErrors >= _maxConsecutiveErrors) return;

    // 高速遷移の抑制。リトライ予約は1本だけにする
    // （onTrackEndとB点到達が続けて発火すると、予約が積み上がって二重スキップになる）
    final now = DateTime.now();
    final sinceLast =
        _lastAdvanceTime == null ? null : now.difference(_lastAdvanceTime!);
    if (sinceLast != null && sinceLast < _minAdvanceInterval) {
      if (!_advanceRetryScheduled) {
        _advanceRetryScheduled = true;
        Future.delayed(_minAdvanceInterval - sinceLast, () {
          _advanceRetryScheduled = false;
          if (mounted) _autoAdvance();
        });
      }
      return;
    }
    _lastAdvanceTime = now;

    final crossfading = ref.read(playlistEngineProvider).isCrossfading;
    final shouldFadeIn = ref.read(playlistPlayerProvider).firstVerseMode &&
        _isFading &&
        !crossfading;
    _cancelFade();
    // 交差中は旧プレイヤーの音量を戻さない（stop 直前に一瞬大きく鳴ってしまう）
    if (!crossfading) {
      try { ref.read(playerProvider).setVolume(_baseVolume); } catch (_) {}
    }

    final plState = ref.read(playlistPlayerProvider);
    final oldTrack = plState.currentTrack;
    final notifier = ref.read(playlistPlayerProvider.notifier);

    // 手動選択のキューがある場合はjumpTo、なければnext()
    final pendingJump = _pendingJumpIndex;
    _pendingJumpIndex = null;

    final nextIdx = pendingJump ?? plState.peekNextTrackIndex();
    final isPreloaded = _preloadedTrackIndex != null && nextIdx == _preloadedTrackIndex;

    bool changed;
    if (pendingJump != null) {
      notifier.jumpTo(pendingJump);
      changed = true;
    } else {
      changed = notifier.next();
    }
    if (!changed) {
      // 単曲リピート → 先頭にシーク
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track != null) {
        ref.read(playerProvider).seek(Duration(milliseconds: track.startMs ?? 0));
      }
      return;
    }

    final newTrack = ref.read(playlistPlayerProvider).currentTrack;
    if (newTrack == null) return;

    if (oldTrack != null && newTrack.isSameItem(oldTrack)) {
      _loadTrackRegion(newTrack);
      _afterTrackSwitch(newTrack, shouldFadeIn: shouldFadeIn);
    } else if (isPreloaded) {
      _swapToPreloaded(newTrack);
      _loadTrackRegion(newTrack);
      _afterTrackSwitch(newTrack, shouldFadeIn: shouldFadeIn);
    } else {
      // 未プリロード → フルリロード（自動遷移なのでローディング画面OK）
      _cancelPreload();
      _preloadCheckTimer?.cancel();
      _pendingFadeIn = shouldFadeIn;
      _loadItem();
    }
  }

  // ----- 手動操作: 次曲 / 前曲 / トラック選択 -----

  /// 手動操作の共通ガード。ロード中なら拒否してtrue返却。
  void _startLoadingTimeout() {
    _loadingTimeoutTimer?.cancel();
    _loadingTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      _cancelLoadingState();
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.info('読込タイムアウト。操作可能です。'),
      );
    });
  }

  void _cancelLoadingState() {
    _loadingTimeoutTimer?.cancel();
    _cancelPreload();
    setState(() {
      _trackLoading = false;
      _preloadingTargetIndex = null;
    });
  }

  bool _guardManualOp() {
    if (_trackLoading || _isPreloading) {
      if (!_loadingSnackShowing) {
        _loadingSnackShowing = true;
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.action('読込中...（タップでキャンセル）',
              label: 'キャンセル', onPressed: _cancelLoadingState),
        ).closed.then((_) => _loadingSnackShowing = false);
      }
      return true;
    }
    return false;
  }

  /// 手動: 次のトラックへ
  Future<void> _manualNext() async {
    if (_guardManualOp()) return;
    final ps = ref.read(playlistPlayerProvider);
    if (!ps.hasNext) return;

    final readiness = _readiness();
    if (readiness == AdvanceReadiness.none) return;
    if (readiness == AdvanceReadiness.sameItem ||
        readiness == AdvanceReadiness.preloaded) {
      // 即遷移可能
      _autoAdvance();
      return;
    }

    // プリロード待ち（スピナー表示、ローディング画面なし）
    final startTrackIdx = ps.currentTrackIndex;
    setState(() => _trackLoading = true);
    _startLoadingTimeout();
    if (!_isPreloading) _preloadNextTrack();
    for (var i = 0; i < 300 && _preloadedTrackIndex == null && mounted; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      // 自動遷移(onBPointReached)が先に実行された場合はキャンセル
      if (ref.read(playlistPlayerProvider).currentTrackIndex != startTrackIdx) {
        _loadingTimeoutTimer?.cancel();
        if (mounted) setState(() => _trackLoading = false);
        return;
      }
    }
    _loadingTimeoutTimer?.cancel();
    if (mounted) setState(() => _trackLoading = false);
    // 自動遷移がまだ実行されていない場合のみ進む
    if (_preloadedTrackIndex != null && mounted &&
        ref.read(playlistPlayerProvider).currentTrackIndex == startTrackIdx) {
      _autoAdvance();
    }
  }

  /// 手動: 前のトラックへ
  /// _manualNext と対称な構造: peekしてから判断し、状態変更はロード完了後
  Future<void> _manualPrev() async {
    if (_guardManualOp()) return;
    final ps = ref.read(playlistPlayerProvider);
    if (!ps.hasPrev) return;

    final prevIdx = ps.peekPrevTrackIndex();
    if (prevIdx == null) return;
    final prevTrack = ps.tracks[prevIdx];
    final current = ps.currentTrack;
    final sameItem = current != null && prevTrack.isSameItem(current);

    if (sameItem) {
      // 同一アイテム → prev()で即移動+シーク（即座に完了）
      ref.read(playlistPlayerProvider.notifier).prev();
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track == null) return;
      _cancelFade();
      _loadTrackRegion(track);
      _afterTrackSwitch(track);
      return;
    }

    // 異なるアイテム → 直接ロード（ロード完了後にprev()で状態変更）
    await _directLoadTrack(prevTrack, prevIdx);
  }

  /// ミックスビューで切り替わった後、前曲側（切替点より前）をタップしたとき。
  /// 前の曲に戻ってその位置から再生し、切り替わりをもう一度聴けるようにする
  /// （2 秒後に次曲が再びプリロードされ、クロスフェードが繰り返される）。
  void _replayPreviousFrom(Duration oldPos) {
    final ps = ref.read(playlistPlayerProvider);
    if (!ps.hasPrev || _trackLoading || _isPreloading) return;
    _pendingReplaySeek = oldPos < Duration.zero ? Duration.zero : oldPos;
    _manualPrev();
  }

  /// 手動: トラック選択（パネルからタップ）
  Future<void> _selectTrack(int trackIndex) async {
    // 最初の曲を開いている最中は一覧は見られるが選べない（同じプレイヤーを取り合うため）
    if (_loading) return;
    if (_guardManualOp()) return;
    final ps = ref.read(playlistPlayerProvider);
    if (trackIndex == ps.currentTrackIndex) return;

    final targetTrack = ps.tracks[trackIndex];
    final current = ps.currentTrack;

    // プリロード済み → 即スワップ
    if (_preloadedTrackIndex == trackIndex) {
      ref.read(playlistPlayerProvider.notifier).jumpTo(trackIndex);
      final track = ref.read(playlistPlayerProvider).currentTrack!;
      _swapToPreloaded(track);
      _loadTrackRegion(track);
      _afterTrackSwitch(track);
      return;
    }

    // 同一アイテム → シークのみ（即座に完了）
    if (current != null && targetTrack.isSameItem(current)) {
      ref.read(playlistPlayerProvider.notifier).jumpTo(trackIndex);
      final track = ref.read(playlistPlayerProvider).currentTrack!;
      _loadTrackRegion(track);
      _afterTrackSwitch(track);
      return;
    }

    // 異なるアイテム → 次曲としてプリロード（自動遷移時にスワップ再生）
    _cancelPreload();
    _pendingJumpIndex = trackIndex;
    _preloadNextTrack(trackIndex);
  }

  // ----- 共通: 直接ロード（前曲 / トラック選択で使用） -----

  Future<void> _directLoadTrack(PlaylistTrack track, [int? jumpToIndex]) async {
    _cancelFade();
    _cancelPreload();
    _startLoadingTimeout();
    setState(() {
      _trackLoading = true;
      _preloadingTargetIndex = jumpToIndex ?? ref.read(playlistPlayerProvider).currentTrackIndex;
    });

    try {
      final item = track.item;
      final player = ref.read(playerProvider);

      // 開く手順（オフライン優先・メタデータ待ち・高音質の音声・速度）は
      // プリロードやミニプレイヤーの前曲と同じ PlaylistEngine.prepare を通す
      await ref
          .read(playlistEngineProvider)
          .prepare(player, track, isStale: () => !mounted)
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      ref.read(videoSourceProvider.notifier).state = VideoSource(
        type: item.isYouTube
            ? VideoSourceType.youtube
            : VideoSourceType.local,
        uri: item.uri,
        title: item.title,
        videoId: item.videoId,
        thumbnailUrl: item.thumbnailUrl,
      );

      if (jumpToIndex != null) {
        ref.read(playlistPlayerProvider.notifier).jumpTo(jumpToIndex);
      }
      _loadTrackRegion(ref.read(playlistPlayerProvider).currentTrack ?? track);
      ref.read(playerProvider).play();
      _afterTrackSwitch(ref.read(playlistPlayerProvider).currentTrack ?? track);
    } catch (_) {
      // 失敗は無視（次のタップで再試行される）
    } finally {
      // ロードが終わったらタイムアウト監視も止める
      // （残すと30秒後に _cancelLoadingState が走り、次曲プリロードを誤って破棄する）
      _loadingTimeoutTimer?.cancel();
      if (mounted) {
        setState(() {
          _trackLoading = false;
          _preloadingTargetIndex = null;
        });
      }
    }
  }

  // ----- 共通: トラック切替後の後処理 -----

  void _afterTrackSwitch(PlaylistTrack track, {bool shouldFadeIn = false}) {
    _preloadedTrackIndex = null;
    _pendingJumpIndex = null;
    _setupPlaylistCallbacks();
    ref.read(loopProvider.notifier).setCurrentItem(track.item.id);
    _startPreloadMonitor();
    // 新しい曲の大きさに合わせた音量を上限にする（下で setVolume / フェードインに使う）
    _baseVolume = _normalizedVolume(track.item);
    if (shouldFadeIn) {
      _startFadeIn();
    } else {
      // スワップ後のボリュームストリーム同期
      // （旧プレイヤーのフェードアウト値が残らないよう新プレイヤーに明示設定）
      try { ref.read(playerProvider).setVolume(_baseVolume); } catch (_) {}
    }
    // ミックスビューから前曲に戻って聴き直す指定があれば、その位置へ
    final replay = _pendingReplaySeek;
    _pendingReplaySeek = null;
    if (replay != null) {
      try { ref.read(playerProvider).seek(replay); } catch (_) {}
    }
    _consecutiveLoadErrors = 0;
    // 字幕（プレイリスト曲切替時）: キャッシュSRT優先、無ければネット取得
    _subtitles.loadFor(track.item);
    // 2秒後に次曲プリロード開始（再生を安定させてから）
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isPreloading && _preloadedTrackIndex == null) {
        _preloadNextTrack();
      }
    });
  }

  void _loadTrackRegion(PlaylistTrack track) {
    // 曲が変わったら前の曲の AB 編集は閉じる
    _editMode = false;
    // AB区間の反映はミニプレイヤー側と共通（PlaylistEngine）
    ref.read(playlistEngineProvider).applyRegion(track);
    if (!track.hasRegion) {
      // 1番だけモード: 区間未設定のトラックに仮想B点を設定
      _applyFirstVerseCut(track);
    }
    if (track.startMs != null) {
      ref.read(playerProvider).seek(Duration(milliseconds: track.startMs!));
    }
    _setupPlaylistCallbacks();
    if (mounted) setState(() {});
  }

  /// 1番だけモード: 波形から切断点を計算してB点にセット
  /// AB設定済みの区間トラックには適用しない（_loadTrackRegionで分岐済み）
  void _applyFirstVerseCut(PlaylistTrack track, [int retryCount = 0]) {
    // フェードアウト監視のみキャンセル（フェードインは中断しない）
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _isFading = false;
    final plState = ref.read(playlistPlayerProvider);
    if (!plState.firstVerseMode) return;

    final durationMs =
        ref.read(playerProvider).state.duration.inMilliseconds;
    if (durationMs <= 0) {
      // duration未取得 → 少し待って再試行（最大5回）
      if (retryCount < 5) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _applyFirstVerseCut(track, retryCount + 1);
        });
      }
      return;
    }

    // キャッシュ or プロバイダから波形を取得
    final waveform = _waveformCache[track.item.id] ??
        ref.read(waveformDataProvider);
    final cutMs = VerseDetector.findCutPoint(
      waveform: waveform,
      durationMs: durationMs,
    );

    if (cutMs != null) {
      final notifier = ref.read(loopProvider.notifier);
      notifier.setPointA(Duration.zero);
      notifier.setPointB(Duration(milliseconds: cutMs));
      if (!ref.read(loopProvider).enabled) notifier.toggleEnabled();
      _startFadeOutMonitor(cutMs);
    }
  }

  /// B点の3秒前からフェードアウトを開始する監視。
  /// ABループでA点に戻った場合も自動的にリセットして次パスで再フェードする。
  void _startFadeOutMonitor(int cutMs) {
    _cancelFade();
    // クロスフェードが有効なら PlaylistEngine 側が旧曲を下げるので、二重にかけない
    if (ref.read(crossfadeProvider) > 0) return;
    final fadeStartMs = cutMs - 3000;
    if (fadeStartMs <= 0) return;

    var fadeStep = 0;
    const fadeSteps = 15; // 200ms × 15 = 3秒

    _fadeTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) {
        _cancelFade();
        return;
      }
      final posMs =
          ref.read(playerProvider).state.position.inMilliseconds;

      if (posMs < fadeStartMs) {
        // フェードゾーン外（A点にシークされた等）→ 状態リセット
        if (_isFading) {
          _isFading = false;
          fadeStep = 0;
          try { ref.read(playerProvider).setVolume(_baseVolume); } catch (_) {}
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
        try {
          ref.read(playerProvider).setVolume(volume * _baseVolume);
        } catch (_) {}
      }
    });
  }

  /// フェードイン（次曲開始時に呼ぶ）
  /// フェードアウト監視タイマー(_fadeTimer)とは独立して動作する。
  void _startFadeIn() {
    _fadeInTimer?.cancel();
    const steps = 5; // 200ms × 5 = 1秒
    var step = 0;
    ref.read(playerProvider).setVolume(0);
    _fadeInTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      step++;
      final volume = (step / steps).clamp(0.0, 1.0);
      try {
        ref.read(playerProvider).setVolume(volume * _baseVolume);
      } catch (_) {}
      if (step >= steps) {
        _fadeInTimer?.cancel();
        _fadeInTimer = null;
      }
    });
  }

  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
    _isFading = false;
  }

  // --- Preload ---

  void _cancelPreload() {
    ref.read(playlistEngineProvider).disarmCrossfade();
    _preloadGeneration++;
    _preloadedTrackIndex = null;
    _preloadingTargetIndex = null;
    _isPreloading = false;
    // プリロードプレイヤーの実行中の操作を確実に中断
    try { ref.read(preloadPlayerProvider).stop(); } catch (_) {}
  }

  void _startPreloadMonitor() {
    _preloadCheckTimer?.cancel();
    _cancelPreload();
    _preloadFailCount = 0;

    if (!_isPlaylist) return;

    _preloadCheckTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkPreload(),
    );
  }

  void _checkPreload() {
    if (!mounted || !_isPlaylist || _loading) return;
    if (_isPreloading || _preloadedTrackIndex != null) return;

    // 連続失敗時はバックオフ（失敗数 × 10秒）、上限5回で停止
    if (_preloadFailCount > 0) {
      if (_preloadFailCount >= 5) return;
      final backoff = Duration(seconds: _preloadFailCount * 10);
      if (_lastPreloadFailTime != null &&
          DateTime.now().difference(_lastPreloadFailTime!) < backoff) {
        return;
      }
    }

    final player = ref.read(playerProvider);
    final position = player.state.position;
    final duration = player.state.duration;

    if (duration <= Duration.zero) return;

    // 1番だけモードではB点を終了地点として使う
    final loop = ref.read(loopProvider);
    final plState = ref.read(playlistPlayerProvider);
    final isFirstVerse =
        plState.firstVerseMode && loop.enabled && loop.hasB;
    final endPoint = isFirstVerse ? loop.pointB! : duration;

    final remaining = endPoint - position;
    // 1番だけモードでは早めにプリロード開始（30秒前）
    var thresholdSec = isFirstVerse
        ? 30
        : endPoint.inSeconds > 120
            ? 30
            : 10;
    // クロスフェードは曲末の無音を除いた位置の fade 秒前から始まる。
    // それまでにプリロードが済むよう、その分だけ早める
    final fadeSec = ref.read(playlistEngineProvider).crossfadeDuration.inSeconds;
    if (fadeSec > 0 && !isFirstVerse) {
      final trailingSec =
          ((_currentItem.trailingSilenceMs ?? 0) / 1000).ceil();
      thresholdSec = math.max(thresholdSec, fadeSec + trailingSec + 10);
    }

    if (remaining.inSeconds <= thresholdSec) {
      _preloadNextTrack();
    }
  }

  Future<void> _preloadNextTrack([int? overrideIndex]) async {
    if (_isPreloading) return;
    _isPreloading = true;
    final gen = ++_preloadGeneration; // この世代のプリロード

    bool isStale() => !mounted || gen != _preloadGeneration;

    try {
      final plState = ref.read(playlistPlayerProvider);
      final int? nextIdx;
      if (overrideIndex != null) {
        nextIdx = overrideIndex;
        _preloadedTrackIndex = null;
      } else {
        nextIdx = plState.peekNextTrackIndex();
      }
      if (nextIdx == null) {
        _isPreloading = false;
        return;
      }

      _preloadingTargetIndex = nextIdx;
      if (mounted) setState(() {});

      final nextTrack = plState.tracks[nextIdx];

      // Same item → seek only at advance time, no preload needed
      final currentTrack = plState.currentTrack;
      if (currentTrack != null && nextTrack.isSameItem(currentTrack)) {
        _isPreloading = false;
        return;
      }

      // ロード機構（キャッシュ優先・メタデータ待ち・シーク・速度設定）は
      // PlaylistEngine に集約してあり、ミニプレイヤー側と同じ実装を通る。
      // manifest は波形の先行生成に再利用する（キャッシュ再生時はnull）。
      final manifest = await ref
          .read(playlistEngineProvider)
          .prepare(ref.read(preloadPlayerProvider), nextTrack,
              isStale: isStale, downloadFirst: true);

      if (isStale()) return;
      _preloadedTrackIndex = nextIdx;
      _preloadFailCount = 0;
      ref.read(playlistEngineProvider).armCrossfade(nextTrack);
      if (mounted) setState(() {});

      // --- 波形の先行読み込み（並行） ---
      final itemId = nextTrack.item.id;
      if (!_waveformCache.containsKey(itemId)) {
        _preloadWaveform(nextTrack, manifest, gen);
      }
    } catch (e) {
      debugPrint('[Preload] 失敗: $e');
      if (gen == _preloadGeneration) {
        _preloadedTrackIndex = null;
        _preloadFailCount++;
        _lastPreloadFailTime = DateTime.now();
      }
    } finally {
      if (gen == _preloadGeneration) {
        _isPreloading = false;
        _preloadingTargetIndex = null;
      }
      if (mounted) setState(() {});
    }
  }

  /// 波形からミックス点（ドロップ / アウトロ）を求めて LoopItem に残す。
  /// 一度求めたものは使い回す（将来の手動上書きを壊さないため）。
  /// 次曲（[preload]）なら、決まった開始位置へプリロード側を取り直す
  Future<void> _updateMixPoints(PlaylistTrack track, List<double> waveform,
      {required bool preload}) async {
    final item = track.item;
    final needPoints = item.mixInMs == null && item.mixOutMs == null;
    // 音量の流れ（おまかせ用）はミックス点より後から入ったので、点があっても無ければ求める
    final needEnergy = item.headDb == null;
    if (!needPoints && !needEnergy) return;
    final engine = ref.read(playlistEngineProvider);
    final duration = (preload ? engine.preloadPlayer : engine.activePlayer)
        .state
        .duration;
    if (duration <= Duration.zero) return;
    final points = needPoints
        ? MixPointDetector.fromWaveform(
            waveform,
            duration.inMilliseconds,
            leadingSilenceMs: item.leadingSilenceMs ?? 0,
            trailingSilenceMs: item.trailingSilenceMs,
          )
        : MixPoints(mixInMs: item.mixInMs, mixOutMs: item.mixOutMs);
    final energy = needEnergy
        ? EnergyProfile.fromWaveform(
            waveform,
            duration.inMilliseconds,
            leadingSilenceMs: item.leadingSilenceMs ?? 0,
            trailingSilenceMs: item.trailingSilenceMs,
            mixInMs: points.mixInMs,
          )
        : null;
    if (points == MixPoints.none && (energy == null || energy.isEmpty)) return;
    await ref
        .read(loopItemsProvider.notifier)
        .saveMixPoints(item.id, points, energy: energy);
    // Hive の box にあるのと同じインスタンスなので item 自体も更新されている
    debugPrint('[MixPoint] ${item.title}: $points ${energy ?? ''}');
    if (preload && needPoints) await engine.realignPreload(track);
  }

  /// 波形を先行生成してキャッシュに保存（fire-and-forget）
  Future<void> _preloadWaveform(
      PlaylistTrack track, StreamManifest? manifest, int gen) async {
    try {
      final item = track.item;
      final service = WaveformService();
      // プリロード側のプレイヤーは準備済みなので長さが分かる（0 なら不明として扱われる）
      final preloadDuration = ref.read(preloadPlayerProvider).state.duration;
      final onPcm = AudioAnalysisService.sinkFor(
          ref.read(loopItemsProvider.notifier), item,
          duration: preloadDuration == Duration.zero ? null : preloadDuration);
      List<double>? waveform;

      // 保存済みの波形があれば音声 DL ごと省く（解析が必要なときは作り直す）
      if (onPcm == null) {
        waveform = await WaveformCache.load(item.id);
        if (waveform != null && waveform.isNotEmpty) {
          if (gen == _preloadGeneration) {
            _waveformCache[item.id] = waveform;
            await _updateMixPoints(track, waveform, preload: true);
          }
          return;
        }
      }

      // 通信せずに使える音声（高音質の音声・自動キャッシュ・オフライン保存）があればそれで
      final localAudio = item.isYouTube && item.videoId != null
          ? await WaveformService.localAudioFor(item.videoId!,
              playingUri: CacheService.offlineVideoPath(item))
          : null;
      if (!item.isYouTube) {
        waveform =
            await service.generateForLocalFile(item.uri, 4000, onPcm: onPcm);
      } else if (localAudio != null) {
        waveform =
            await service.generateForLocalFile(localAudio, 4000, onPcm: onPcm);
      } else if (manifest != null) {
        // YouTube: 音声をダウンロードして波形生成
        final muxed = manifest.muxed.sortByVideoQuality();
        if (muxed.isNotEmpty) {
          final tempDir = await getTemporaryDirectory();
          final tempFile = File(
              '${tempDir.path}/u2b_waveform_preload_${item.id}.tmp');
          final ytService = ref.read(youtubeServiceProvider);
          final dataStream =
              ytService.yt.videos.streamsClient.get(muxed.first);
          final sink = tempFile.openWrite();
          var bytes = 0;
          final sub = dataStream.listen((chunk) {
            sink.add(chunk);
            bytes += chunk.length;
          });
          try {
            await sub.asFuture<void>().timeout(const Duration(seconds: 15));
          } on TimeoutException {
            // pass
          } finally {
            try { await sub.cancel().timeout(const Duration(seconds: 2)); } catch (_) {}
            try { await sink.flush().timeout(const Duration(seconds: 2)); } catch (_) {}
            try { await sink.close().timeout(const Duration(seconds: 2)); } catch (_) {}
          }
          if (gen != _preloadGeneration) {
            try { await tempFile.delete(); } catch (_) {}
            return;
          }
          if (bytes > 100000) {
            try {
              waveform = await service.generateForLocalFile(tempFile.path, 4000,
                  onPcm: onPcm);
            } finally {
              try { await tempFile.delete(); } catch (_) {}
            }
          }
        }
      }

      if (waveform != null && waveform.isNotEmpty) {
        await WaveformCache.save(item.id, waveform);
        if (gen == _preloadGeneration) {
          _waveformCache[item.id] = waveform;
          await _updateMixPoints(track, waveform, preload: true);
        }
      }
    } catch (_) {
      // 波形プリロード失敗は無視（再生時に再試行される）
    }
  }

  void _swapToPreloaded(PlaylistTrack newTrack) {
    // プリロード状態をクリア（プレイヤーはstopしない — これからスワップして使う）
    _preloadGeneration++;
    _preloadedTrackIndex = null;
    _preloadingTargetIndex = null;
    _isPreloading = false;

    // 動画ソースを先に更新しておく（スワップ前にUIが参照できるように）。
    // URI はプリロード側が実際に開いたもの（キャッシュのファイルかストリーム URL）。
    // 曲の登録 URL（YouTube のページ）を入れると書き出し・波形が使えない
    final item = newTrack.item;
    final openedUri =
        ref.read(preloadPlayerProvider).state.playlist.medias.firstOrNull?.uri;
    ref.read(videoSourceProvider.notifier).state = VideoSource(
      type: item.isYouTube
          ? VideoSourceType.youtube
          : VideoSourceType.local,
      uri: openedUri ?? item.uri,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );

    // スロット入替・旧プレイヤーの停止・新プレイヤーの再生開始は
    // PlaylistEngine に集約（ミニプレイヤー側と同じ実装を通る）
    ref.read(playlistEngineProvider).swapSlots();

    // 再生カウント: トラック切替
    ref.read(loopProvider.notifier).setCurrentItem(item.id);

    // Apply cached waveform or generate fresh
    final cachedWaveform = _waveformCache.remove(item.id);
    if (cachedWaveform != null) {
      ref.read(waveformDataProvider.notifier).state = cachedWaveform;
      ref.read(waveformErrorProvider.notifier).state = null;
      ref.read(waveformLoadingProvider.notifier).state = false;
    } else {
      ref.read(waveformDataProvider.notifier).state = null;
      ref.read(waveformErrorProvider.notifier).state = null;
      final source = ref.read(videoSourceProvider);
      if (source != null) {
        _generateWaveform(source, item);
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  // --- Loading ---

  /// 曲を開く（手順は PlayerLoader、AB 設定画面と同じ）。
  /// オフライン保存があればそれを優先し、YouTube の波形用音声は裏で先読みする
  Future<void> _loadItem() async {
    _cancelFade();
    _progress.begin();
    setState(() {
      _loading = true;
      _loadError = null;
      _activeRegionIdx = -1;
    });

    // Stop preload player to free resources
    try {
      ref.read(preloadPlayerProvider).stop();
    } catch (_) {}

    // Reset player state
    ref.read(videoSourceProvider.notifier).state = null;
    ref.read(loopProvider.notifier).reset();
    ref.read(waveformDataProvider.notifier).state = null;

    try {
      final item = _currentItem;
      final media = await _loader.load(item, onOpened: (m) {
        final manifest = m.manifest;
        if (manifest != null) {
          _waveform.prefetchThenGenerate(
              item, manifest, () => _generateWaveform(m.source, item));
        }
      });
      await _finishLoading(item, media.source);
    } on LoadAborted {
      // 画面を離れた
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = AppErrors.describe(e);
        });
        // プレイリストモード: 自動で次のトラックにスキップ（上限あり）
        if (_isPlaylist) {
          _consecutiveLoadErrors++;
          if (_consecutiveLoadErrors < _maxConsecutiveErrors) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && _loadError != null) _autoAdvance();
            });
          }
        }
      }
    }
  }

  /// 開けた後の画面側の仕上げ: 区間・コールバック・再生開始・字幕・波形
  Future<void> _finishLoading(LoopItem item, VideoSource source) async {
    final player = ref.read(playerProvider);

    // Setup regions / AB
    if (_isPlaylist) {
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track != null) {
        _loadTrackRegion(track);
      }
    } else {
      _setupRegions(item);
    }

    // Setup playlist callbacks
    _setupPlaylistCallbacks();

    _loader.finish();
    setState(() {
      _loading = false;
      _trackLoading = false;
    });
    _consecutiveLoadErrors = 0;

    // 再生カウント: 現在のアイテムを設定
    ref.read(loopProvider.notifier).setCurrentItem(item.id);

    // 音量正規化（前に測ってあればこの時点で合う。無ければ波形ができたとき）
    _applyVolumeNorm(item);

    // Auto-play + バックグラウンド再生サービス開始
    player.play();
    WakelockPlus.enable();
    PipBridge.startPlaybackService(item);

    // フルリロードパスでのフェードイン（_advanceToNextから来た場合）
    if (_pendingFadeIn) {
      _pendingFadeIn = false;
      _startFadeIn();
    }

    // Start preload monitor for playlist mode（2秒後に開始、再生を安定させてから）
    if (_isPlaylist) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && !_isPreloading && _preloadedTrackIndex == null) {
          _startPreloadMonitor();
          _preloadNextTrack();
        }
      });
    }

    // Waveform（ローカルは即。YouTube は音声の先読みが済んでいれば）
    if (_waveform.shouldGenerateNow(source)) {
      _generateWaveform(source, item);
    }

    // 字幕: オフラインキャッシュがあればファイルから（通信不要）、無ければ取得
    _subtitles.loadFor(item);
  }

  /// 字幕ボタンの長押し: 言語を選ぶ（メイン / サブ）
  void _showSubtitleLanguagePicker() {
    showSubtitleLanguageSheet(
      context,
      tracks: ref.read(subtitleTracksProvider),
      mainLanguage: ref.read(subtitleLanguageProvider),
      subLanguage: ref.read(subtitleSubLanguageProvider),
      onMain: (track) =>
          _subtitles.fetch(_currentItem, language: track.languageCode),
      onSub: _subtitles.fetchSub,
      onClearSub: _subtitles.clearSub,
    );
  }

  void _setupRegions(LoopItem item) {
    final regions = item.effectiveRegions;
    if (regions.isNotEmpty) {
      setState(() => _activeRegionIdx = 0);
      _loadRegion(regions[0]);
    }
  }

  void _loadRegion(LoopRegion region) {
    final notifier = ref.read(loopProvider.notifier);
    notifier.setPointA(region.pointAMs != null
        ? Duration(milliseconds: region.pointAMs!)
        : null);
    notifier.setPointB(region.pointBMs != null
        ? Duration(milliseconds: region.pointBMs!)
        : null);
    if (!ref.read(loopProvider).enabled && region.hasA && region.hasB) {
      notifier.toggleEnabled();
    }
  }

  void _selectRegion(int index) {
    final regions = _currentItem.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    _syncRegionFromLoop(); // 切替前に保存
    setState(() => _activeRegionIdx = index);
    _loadRegion(regions[index]);
    // Seek to region start
    if (regions[index].pointAMs != null) {
      ref
          .read(playerProvider)
          .seek(Duration(milliseconds: regions[index].pointAMs!));
    }
  }

  void _clearRegion() {
    _syncRegionFromLoop(); // 切替前に保存
    setState(() {
      _activeRegionIdx = -1;
      _editMode = false;
    });
    final notifier = ref.read(loopProvider.notifier);
    notifier.reset();
  }

  // --- Region editing (single mode) ---

  static const _maxRegions = AppLimits.maxRegions;

  /// 区間一覧の編集ルール（AB 設定画面と同じ）。状態は item の regions 本体と
  /// _activeRegionIdx で、操作のたびにこれを作って使う。
  /// その場で書き換えるので、表示用のコピー（effectiveRegions）ではなく本体リストを取る
  RegionEditController get _regionEditor => RegionEditController(
      regions: _currentItem.ensureRegions(), selected: _activeRegionIdx);

  /// 現在のループ状態を選択中の区間に同期
  void _syncRegionFromLoop() {
    if (_isPlaylist) return;
    final loop = ref.read(loopProvider);
    _regionEditor.syncFromLoop(loop.pointA, loop.pointB);
  }

  /// 区間の変更をLoopItemに保存（旧互換の pointA/B も合わせる）
  Future<void> _saveRegions() async {
    if (_isPlaylist) return;
    final item = _currentItem;
    item.setRegions(item.regions);
    await ref.read(loopItemsProvider.notifier).update(item);
  }

  void _addRegion() {
    if (_isPlaylist) return;
    _syncRegionFromLoop();
    final editor = _regionEditor;
    final position = ref.read(playerProvider).state.position;
    final region = editor.add(positionMs: position.inMilliseconds);
    if (region == null) return;

    setState(() {
      _activeRegionIdx = editor.selected;
      _editMode = true;
    });
    _loadRegion(region);
    _saveRegions();
  }

  void _renameRegion(int index) async {
    final regions = _currentItem.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    final name = await _showRegionNameDialog(regions[index].name);
    if (name == null) return;
    setState(() => _regionEditor.rename(index, name));
    _saveRegions();
  }

  /// 削除（最後の 1 つも消せる。区間なし = 全体を再生）
  void _deleteRegion(int index) async {
    final regions = _currentItem.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    final ok = await AppDialogs.confirmDelete(context,
        message: '区間「${regions[index].name}」を削除しますか？');
    if (!ok || !mounted) return;
    final editor = _regionEditor;
    if (!editor.delete(index)) return;
    setState(() {
      _activeRegionIdx = editor.selected;
      if (editor.current == null) _editMode = false;
    });
    final current = editor.current;
    if (current != null) {
      _loadRegion(current);
    } else {
      ref.read(loopProvider.notifier).reset();
    }
    _saveRegions();
  }

  Future<String?> _showRegionNameDialog(String initial) =>
      AppDialogs.prompt(context,
          title: '区間名',
          initialValue: initial,
          hintText: '区間名を入力',
          maxLength: AppLimits.regionNameMaxLength);

  void _showRegionMenu(int index) {
    final regions = _currentItem.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    AppSheets.actions(
      context,
      title: regions[index].name,
      actions: [
        SheetAction(
          icon: Icons.edit,
          label: '名前を変更',
          onTap: () => _renameRegion(index),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => _deleteRegion(index),
        ),
      ],
    );
  }

  /// 編集モード終了時にAB値を保存
  void _finishEdit() {
    _syncRegionFromLoop();
    _saveRegions();
    setState(() => _editMode = false);
  }

  // --- PiP ---

  void _enterPiP() async {
    _updatePiPPlayState();
    try {
      await PipBridge.enterPiP(_currentItem);
    } catch (e) {
      debugPrint('enterPiP failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.info('PiPに入れませんでした'),
        );
      }
    }
  }

  void _updatePiPPlayState() =>
      PipBridge.updatePlayState(ref.read(playerProvider).state.playing);

  // --- Export ---

  void _showExportDialog({bool fullTrack = false}) {
    final loop = ref.read(loopProvider);
    if (!fullTrack && !loop.hasBothPoints) return;

    String subtitle;
    if (fullTrack) {
      final dur = ref.read(playerProvider).state.duration;
      subtitle = '全体 (${TimeUtils.formatShort(dur)})';
    } else {
      final aStr = TimeUtils.formatShort(loop.pointA!);
      final bStr = TimeUtils.formatShort(loop.pointB!);
      final durationSec =
          (loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() /
              1000;
      subtitle = '$aStr - $bStr (${durationSec.toStringAsFixed(1)}s)';
    }

    showExportFormatDialog(
      context,
      title: fullTrack ? '全体を書き出し' : '区間を書き出し',
      rangeText: subtitle,
      askQuality: ExportSource.canPickQuality(_currentItem),
    ).then((choice) {
      if (choice == null || !mounted) return;
      _executeExport(choice, fullTrack: fullTrack);
    });
  }

  Future<void> _executeExport(ExportChoice choice,
      {bool fullTrack = false}) async {
    final loop = ref.read(loopProvider);
    if (!fullTrack && !loop.hasBothPoints) return;

    final source = ref.read(videoSourceProvider);
    if (source == null) return;

    final inputUri = source.type == VideoSourceType.local
        ? _currentItem.uri
        : source.uri;

    final int startMs;
    final int endMs;
    if (fullTrack) {
      startMs = 0;
      endMs = ref.read(playerProvider).state.duration.inMilliseconds;
    } else {
      startMs = loop.pointA!.inMilliseconds;
      endMs = loop.pointB!.inMilliseconds;
    }

    if (!mounted) return;
    await runItemExportFlow(
      context,
      item: _currentItem,
      fallbackUri: inputUri,
      startMs: startMs,
      endMs: endMs,
      choice: choice,
      title: _currentItem.title,
    );
  }

  // --- Waveform ---

  void _retryWaveform() {
    final source = ref.read(videoSourceProvider);
    if (source != null) _generateWaveform(source, _currentItem);
  }

  /// 波形を作って provider に流し（手順は WaveformLoader、AB 設定画面と同じ）、
  /// できたら 1 番だけモードの切断点・ミックス点・音量正規化を更新する。
  /// [item] は開いたときの曲（先読みが終わる頃には次の曲に進んでいることがある）
  Future<void> _generateWaveform(VideoSource source, LoopItem item) async {
    final waveform = await _waveform.generate(source, item);
    if (waveform == null || !mounted) return;
    _waveformCache[item.id] = waveform;
    if (_isPlaylist) {
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track != null && !track.hasRegion) {
        _applyFirstVerseCut(track);
      }
      if (track != null) {
        unawaited(_updateMixPoints(track, waveform, preload: false));
      }
    }
    // 波形を作ったときに曲の大きさも測って保存される。まだこの曲なら音量に反映する
    final nowPlaying = _isPlaylist
        ? ref.read(playlistPlayerProvider).currentTrack?.item.id == item.id
        : _currentItem.id == item.id;
    if (nowPlaying) _applyVolumeNorm(item);
  }

  /// 音量正規化がオンなら、その曲の大きさ（保存されている最新の値）に合わせた音量。オフなら 100
  double _normalizedVolume(LoopItem item) {
    if (!ref.read(volumeNormProvider)) return 100.0;
    final latest = ref.read(loopItemsProvider.notifier).byId(item.id) ?? item;
    return Loudness.volumeFor(latest.loudnessDb);
  }

  /// [_normalizedVolume] を今のプレイヤーに反映する（フェード中は上限だけ更新）
  void _applyVolumeNorm(LoopItem item) {
    _baseVolume = _normalizedVolume(item);
    if (_isFading) return;
    try {
      ref.read(playerProvider).setVolume(_baseVolume);
    } catch (_) {}
  }



  // --- Track context menu ---

  void _showTrackMenu(int trackIndex, PlaylistTrack track) {
    final isCurrent =
        ref.read(playlistPlayerProvider).currentTrackIndex == trackIndex;
    AppSheets.actions(
      context,
      title: track.displayName,
      actions: [
        if (!isCurrent)
          SheetAction(
            icon: Icons.play_arrow,
            label: 'この曲にスキップ',
            onTap: () => _selectTrack(trackIndex),
          ),
        SheetAction(
          icon: Icons.label_outline,
          label: 'タグを編集',
          onTap: () => ItemTagSheet.show(context, ref, track.item),
        ),
        if (widget.playlistId != null)
          SheetAction(
            icon: Icons.playlist_remove,
            label: 'プレイリストから削除',
            destructive: true,
            onTap: () => _removeTrackFromPlaylist(trackIndex, track),
          ),
      ],
    );
  }

  void _removeTrackFromPlaylist(int trackIndex, PlaylistTrack track) async {
    // プレイリスト詳細のスワイプ削除と同じく確認してから
    final ok = await AppDialogs.confirmDelete(context,
        message: '「${track.item.title}」をプレイリストから削除しますか？');
    if (!ok || !mounted) return;
    final isCurrent =
        ref.read(playlistPlayerProvider).currentTrackIndex == trackIndex;

    final removed = ref
        .read(playlistPlayerProvider.notifier)
        .removeTrack(trackIndex);
    if (!removed) return;

    // プリロード状態をリセット（インデックスがずれるため）
    _cancelPreload();

    if (widget.playlistId != null) {
      await ref
          .read(playlistsProvider.notifier)
          .removeItem(widget.playlistId!, track.item.id);
    }

    // 再生中トラックを削除した場合: 次のトラックにスキップ
    if (isCurrent) {
      final newTrack = ref.read(playlistPlayerProvider).currentTrack;
      if (newTrack != null) {
        _cancelFade();
        _loadItem();
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success('「${track.item.title}」を削除しました'),
      );
    }
  }

  // --- Playlist panel (inline) ---

  /// 曲リストの中身（TrackList）。[dense] は全画面ドロワー用（行を詰め、送らない）
  Widget _buildTrackList({bool dense = false, double bottomInset = 0}) {
    return TrackList(
      controller: dense ? null : _trackListController,
      dense: dense,
      bottomInset: bottomInset,
      preloadingIndex: _preloadingTargetIndex,
      preloadedIndex: _preloadedTrackIndex,
      onSelect: _selectTrack,
      onMenu: _showTrackMenu,
    );
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    // 再生状態の同期: PiP + 通知コントローラー
    ref.listen(playingProvider, (_, next) {
      PipBridge.notifyPlayState(
          playing: next.valueOrNull ?? false, item: _currentItem);
    });

    // PiP中は映像をアプリのルートが描くので、ここでは何も描かない。
    // Videoウィジェットを2つ積むと media_kit のコントローラを取り合うため。
    // （この画面自体は Offstage で生かされたままなので状態は失われない）
    if (ref.watch(pipModeProvider)) return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // Watch playlist provider for reactivity
    final plState = _isPlaylist ? ref.watch(playlistPlayerProvider) : null;
    final displayTitle = _isPlaylist
        ? (plState?.currentTrack?.displayName ?? _currentItem.title)
        : _currentItem.title;

    // 再生中はガラス風: AppBar を透明にして背景を上まで通し、
    // 曲名は動画の下に出すので AppBar にはプレイリスト名だけ（単体は空）。
    // 全画面と横レイアウトは AppBar を置かない（横は PlayerShell の topBar がその代わり）
    final glassLook = !_isFullscreen;
    final showAppBar = !_isFullscreen && !(isLandscape && glassLook);

    return PopScope(
      // 全画面中の「戻る」は全画面の解除（画面は閉じない）
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _activateMiniPlayer();
        } else if (_isFullscreen) {
          _exitFullscreen();
        }
      },
      child: Scaffold(
      extendBodyBehindAppBar: glassLook,
      appBar: !showAppBar
          ? null
          : AppBar(
        backgroundColor: glassLook ? Colors.transparent : null,
        surfaceTintColor: glassLook ? Colors.transparent : null,
        centerTitle: glassLook,
        title: glassLook
            ? Text(
                widget.playlistName ?? '',
                style: textTheme.labelMedium!
                    .copyWith(color: textTheme.bodySmall!.color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isPlaylist && widget.playlistName != null)
              Text(
                widget.playlistName!,
                style: textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              displayTitle,
              style: textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: _buildAppBarActions(),
      ),
      // 読み込み中も失敗時も画面は再生画面のまま。動画枠だけが状態を映す（[_stageStatus]）
      body: _buildPlayerView(bottomInset),
    ),
    );
  }

  /// 動画枠に出す待ち状態。読み込み中は進捗、失敗なら再試行。どちらでもなければ null
  Widget? get _stageStatus {
    if (_loading) {
      return PlayerLoadingStage(
        item: _currentItem,
        progress: _progress.progress,
        status: _progress.status,
      );
    }
    if (_loadError != null) {
      return PlayerErrorView(
        message: _loadError!,
        stoppedByRepeatedErrors:
            _isPlaylist && _consecutiveLoadErrors >= _maxConsecutiveErrors,
        onRetry: () {
          _consecutiveLoadErrors = 0;
          _loadItem();
        },
        onSkip: _isPlaylist
            ? () {
                _consecutiveLoadErrors = 0;
                _autoAdvance();
              }
            : null,
      );
    }
    return null;
  }

  void _activateMiniPlayer() {
    final item = _currentItem;
    final plState = _isPlaylist ? ref.read(playlistPlayerProvider) : null;
    ref.read(miniPlayerProvider.notifier).activate(
      item: item,
      playlistItems: widget.playlistItems,
      initialIndex: plState?.currentTrackIndex ?? widget.initialIndex,
      regionSelections: widget.regionSelections,
      disabledItemIds: widget.disabledItemIds,
      playlistName: widget.playlistName,
      playlistId: widget.playlistId,
    );

    // プレイリストモード: dispose 後も動く進行役を立てる（画面側のコールバックと置き換わる）。
    // ref.read は dispose 後に使えないので、provider コンテナに生き続けるものをここで渡す
    if (_isPlaylist) {
      _miniTransport = MiniPlayerTransport(
        engine: ref.read(playlistEngineProvider),
        loop: ref.read(loopProvider.notifier),
        playlist: ref.read(playlistPlayerProvider.notifier),
        mini: ref.read(miniPlayerProvider.notifier),
      )..start();
    }
  }

  // =====================================================================
  // 横画面レイアウト
  // =====================================================================

  /// 全画面に入る（動画の全画面ボタンから）。横に固定して没入表示にする。
  /// 端末を横に回しただけでは入らない（横画面は [PlayerShell] の横レイアウト）
  void _enterFullscreen() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    setState(() {
      _isFullscreen = true;
      _showFullscreenOverlay = true;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _resetOverlayTimer();
  }

  /// 全画面を解除する（解除ボタン・ダブルタップ・戻る）。向きの固定を外すだけなので、
  /// 端末を横に持ったままなら横レイアウト、縦に戻せば縦レイアウトになる
  void _exitFullscreen() {
    if (!_isFullscreen) return;
    setState(() {
      _isFullscreen = false;
      _showRightDrawer = false;
    });
    _overlayHideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _toggleFullscreenOverlay() {
    setState(() => _showFullscreenOverlay = !_showFullscreenOverlay);
    if (_showFullscreenOverlay) _resetOverlayTimer();
  }

  void _resetOverlayTimer() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showFullscreenOverlay = false);
    });
  }

  /// 全画面の右ドロワー（モード別）。一覧と最小限の操作だけ。
  /// AB 編集はここではせず、全画面を解除して横レイアウト（縦と同じ部品）で行う
  Widget _buildFullscreenDrawer(double bottomInset) {
    if (_isPlaylist) {
      final plState = ref.watch(playlistPlayerProvider);
      return Column(
        children: [
          FullscreenPlaylistControls(
            onShuffle: _isPreloading ? null : _toggleShuffle,
            onRepeat: _cycleRepeatMode,
            onPrev: plState.hasPrev && !_trackLoading ? _manualPrev : null,
            onNext: plState.hasNext && !_trackLoading ? _manualNext : null,
            onMore: _showMoreSheet,
          ),
          Expanded(child: _buildTrackList(dense: true, bottomInset: bottomInset)),
        ],
      );
    }

    // 単体再生: ループ ON/OFF・編集・書出しの行 + 区間の一覧
    final regions = _currentItem.effectiveRegions;
    final hasSource = ref.watch(videoSourceProvider) != null;
    return FullscreenRegionDrawer(
      regions: regions,
      activeIndex: _activeRegionIdx,
      loop: ref.watch(loopProvider),
      bottomInset: bottomInset,
      onToggleLoop:
          hasSource ? ref.read(loopProvider.notifier).toggleEnabled : null,
      // 編集は全画面の外で（横レイアウトに AB 編集の板が出る）
      onEdit: () {
        _exitFullscreen();
        setState(() => _editMode = true);
      },
      onExport: ({required fullTrack}) => _showExportDialog(fullTrack: fullTrack),
      onSelectAll: _clearRegion,
      onSelect: _selectRegion,
      onMenu: _showRegionMenu,
      // 追加すると編集に入るので、全画面は解除する
      onAdd: regions.length < _maxRegions
          ? () {
              _exitFullscreen();
              _addRegion();
            }
          : null,
    );
  }

  /// 全画面（FullscreenPlayerView）。コントロールの表示とドロワーの開閉はこの State が持つ
  Widget _buildFullscreenView(double bottomInset) {
    return FullscreenPlayerView(
      title: _isPlaylist
          ? (ref.read(playlistPlayerProvider).currentTrack?.displayName ??
              _currentItem.title)
          : _currentItem.title,
      bottomInset: bottomInset,
      showOverlay: _showFullscreenOverlay,
      drawerOpen: _showRightDrawer,
      drawer: _buildFullscreenDrawer(bottomInset),
      onToggleOverlay: _toggleFullscreenOverlay,
      onToggleDrawer: () =>
          setState(() => _showRightDrawer = !_showRightDrawer),
      onExit: _exitFullscreen,
      onSubtitleLongPress: _showSubtitleLanguagePicker,
      onRetryWaveform: _retryWaveform,
    );
  }

  /// 縦の AppBar と横レイアウトの topBar で同じ操作: 字幕切替・PiP
  List<Widget> _buildAppBarActions() => [
        // 字幕モード切替（タップ: OFF→カラオケ→リリクス→OFF、長押し: 言語選択）
        SubtitleToggleButton(onLongPress: _showSubtitleLanguagePicker),
        if (Platform.isAndroid || Platform.isIOS)
          IconButton(
            icon: const Icon(Icons.picture_in_picture_alt,
                size: AppIconSizes.ml),
            onPressed: _enterPiP,
            tooltip: 'ピクチャーインピクチャー',
          ),
      ];

  /// 横レイアウトで AppBar の代わりに動画の上へ出す 1 行（プレイリスト名 + 同じ操作）
  Widget _buildWideTopBar() => PlayerWideTopBar(
        title: widget.playlistName ?? '',
        actions: _buildAppBarActions(),
      );

  /// 横レイアウトの AB 編集の板（動画の上）。縦ではコントローラーの中に出す同じ部品
  Widget _buildWideEditPanel(Widget controls, {String? subtitle}) {
    return AbEditPanel(
      key: const ValueKey('abEditPanel'),
      title: 'AB 区間を編集',
      subtitle: subtitle,
      child: controls,
    );
  }

  Widget _buildPlayerView(double bottomInset) {
    // 全画面はボタンで入る別物。端末の向きだけでは入らない
    if (_isFullscreen) return _buildFullscreenView(bottomInset);
    final wide =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    // プレイリスト・単体とも同じ骨組み（PlayerShell。横画面は左右に分かれる）。
    // 違うのは曲名行のチップ・中段のパネル・コントローラーの中身だけ。
    // 横画面では AB 編集ブロックをコントローラーに入れず（高さが足りない）、
    // パネルと同じ場所（動画の上）に板で出す
    final panelOpen = _panelOpen;
    if (_isPlaylist) {
      final plState = ref.watch(playlistPlayerProvider);
      final nextIdx = plState.peekNextTrackIndex();
      // AB 編集（「その他」→「AB区間を編集」）用
      final plLoop = ref.watch(loopProvider);
      final plNotifier = ref.read(loopProvider.notifier);
      final plHasSource = ref.watch(videoSourceProvider) != null;
      final item = plState.currentTrack?.item;
      final currentIdx = plState.currentTrackIndex;
      final subParts = <String>[
        ...?item?.musicInfoParts,
        currentIdx != null
            ? '${currentIdx + 1} / ${plState.trackCount}'
            : '- / ${plState.trackCount}',
      ];
      final plEditBlock = AbEditControls(
        loop: plLoop,
        step: plLoop.adjustStep,
        onStepChanged: plNotifier.setStep,
        onSeek: _seekTo,
        onPointA: plNotifier.setPointA,
        onPointB: plNotifier.setPointB,
        onSwap: plNotifier.swapPoints,
        onSetA: plHasSource
            ? () => plNotifier.setPointA(ref.read(playerProvider).state.position)
            : null,
        onSetB: plHasSource
            ? () => plNotifier.setPointB(ref.read(playerProvider).state.position)
            : null,
      );
      return PlayerShell(
        item: _currentItem,
        wide: wide,
        topBar: wide ? _buildWideTopBar() : null,
        video: _stageStatus ??
            (_hideVideo
                ? null
                : TransitionStage(
                    currentItem: _currentItem,
                    onFullscreen: _enterFullscreen,
                  )),
        header: NowPlayingHeader(
          title: plState.currentTrack?.displayName ?? '',
          subtitle: subParts.join('  ·  '),
          chip: nextIdx != null
              ? NextTrackChip(
                  track: plState.tracks[nextIdx],
                  onTap: () => _setPanelOpen(true),
                )
              : null,
        ),
        panel: panelOpen
            ? _buildTrackListPanel()
            : wide && _editMode
                ? _buildWideEditPanel(plEditBlock,
                    subtitle: plState.currentTrack?.displayName)
                : null,
        controller: PlaylistBottomBar(
          seekbar: PlaylistSeekArea(
            compact: _compactSeekbar,
            waveHeight: 96,
            mixHeight: 120,
            onToggleCompact: () =>
                setState(() => _compactSeekbar = !_compactSeekbar),
            onRetryWaveform: _retryWaveform,
            onReplayPrevious: _replayPreviousFrom,
            waveformFor: (item) => _waveformCache[item.id],
            titleFor: (item) => item.title,
          ),
          listOpen: panelOpen,
          shuffle: plState.shuffle,
          onShuffle: _isPreloading ? null : _toggleShuffle,
          repeatMode: plState.repeatMode,
          onRepeat: _cycleRepeatMode,
          onPrev: plState.hasPrev && !_trackLoading ? _manualPrev : null,
          onNext: plState.hasNext && !_trackLoading ? _manualNext : null,
          onMore: _showMoreSheet,
          onToggleList: () => _setPanelOpen(!panelOpen),
          firstVerse: plState.firstVerseMode,
          onToggleFirstVerse: _toggleFirstVerseMode,
          editing: _editMode,
          onFinishEdit: _finishEdit,
          onSetA: plHasSource
              ? () => plNotifier.setPointA(ref.read(playerProvider).state.position)
              : null,
          onSetB: plHasSource
              ? () => plNotifier.setPointB(ref.read(playerProvider).state.position)
              : null,
          onRegister: plLoop.hasBothPoints
              ? () => _saveCurrentAbAsRegion(
                  plLoop.pointA!.inMilliseconds, plLoop.pointB!.inMilliseconds)
              : null,
          editBlock: wide ? null : plEditBlock,
        ),
      );
    }

    // 単体再生: 区間チップ・区間パネル・単体用コントローラー
    final loop = ref.watch(loopProvider);
    final notifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final regions = _currentItem.effectiveRegions;
    final activeRegion =
        _activeRegionIdx >= 0 && _activeRegionIdx < regions.length
            ? regions[_activeRegionIdx]
            : null;
    final item = _currentItem;
    final duration = ref.watch(durationProvider).valueOrNull;
    final subParts = <String>[
      ...item.musicInfoParts,
      if (duration != null && duration > Duration.zero)
        TimeUtils.formatShort(duration),
    ];
    final String regionText;
    if (activeRegion == null) {
      regionText = '全体';
    } else if (_editMode) {
      regionText = '${activeRegion.name}（編集中）';
    } else {
      regionText =
          '${activeRegion.name}  ${TimeUtils.formatShortNullable(loop.pointA)} - ${TimeUtils.formatShortNullable(loop.pointB)}';
    }

    final editBlock = AbEditControls(
      loop: loop,
      step: loop.adjustStep,
      onStepChanged: notifier.setStep,
      onSeek: _seekTo,
      onPointA: notifier.setPointA,
      onPointB: notifier.setPointB,
      onSwap: notifier.swapPoints,
      onSetA: hasSource
          ? () => notifier.setPointA(ref.read(playerProvider).state.position)
          : null,
      onSetB: hasSource
          ? () => notifier.setPointB(ref.read(playerProvider).state.position)
          : null,
    );

    return PlayerShell(
      item: item,
      wide: wide,
      topBar: wide ? _buildWideTopBar() : null,
      video: _stageStatus ??
          (_hideVideo
              ? null
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoPlayerWidget(
                      useAspectRatio: false,
                      onFullscreen: _enterFullscreen,
                    ),
                    const LyricsOverlay(),
                  ],
                )),
      header: NowPlayingHeader(
        title: item.title,
        subtitle: subParts.join('  ·  '),
        chip: HeaderChip(
          leading: Icon(
            activeRegion == null ? Icons.all_inclusive : Icons.repeat,
            size: AppIconSizes.s,
            color: AppTheme.accentGreen,
          ),
          label: '区間',
          text: regionText,
          onTap: () => _setPanelOpen(true),
        ),
      ),
      panel: panelOpen
          ? _buildRegionPanel(regions)
          : wide && _editMode
              ? _buildWideEditPanel(editBlock, subtitle: activeRegion?.name)
              : null,
      controller: SinglePlayerBar(
        seekbar: LoopSeekbar(
          compact: _compactSeekbar,
          onToggleCompact: () =>
              setState(() => _compactSeekbar = !_compactSeekbar),
          allowMarkerDrag: _editMode,
          onRetryWaveform: _retryWaveform,
        ),
        regionsOpen: panelOpen,
        loop: loop,
        onToggleLoop: notifier.toggleEnabled,
        editing: _editMode,
        canEdit: activeRegion != null,
        onToggleRegions: () => _setPanelOpen(!panelOpen),
        onEdit: () => setState(() => _editMode = true),
        onFinishEdit: _finishEdit,
        onMore: _showSingleMoreSheet,
        onSetA: hasSource
            ? () => notifier.setPointA(ref.read(playerProvider).state.position)
            : null,
        onSetB: hasSource
            ? () => notifier.setPointB(ref.read(playerProvider).state.position)
            : null,
        editBlock: wide ? null : editBlock,
      ),
    );
  }

  /// 単体再生の「その他」シート
  void _showSingleMoreSheet() {
    SingleMoreSheet.show(
      context,
      SingleMoreSheet(
        onExport: () => _showExportDialog(
            fullTrack: !ref.read(loopProvider).hasBothPoints),
        hideVideo: _hideVideo,
        onHideVideoChanged: (v) => setState(() => _hideVideo = v),
      ),
    );
  }

  /// 開閉できる AB 区間の一覧（共通部品）。行: 全体 / 各区間
  Widget _buildRegionPanel(List<LoopRegion> regions) {
    return RegionPanel(
      key: const ValueKey('regionPanel'),
      regions: regions,
      selectedIndex: _activeRegionIdx,
      showAll: true,
      onSelectAll: _clearRegion,
      onSelect: _selectRegion,
      onMenu: _showRegionMenu,
      onAdd: regions.length < _maxRegions ? _addRegion : null,
    );
  }

  /// 中段パネル（プレイリスト: トラック一覧、単体: AB 区間）の開閉。
  /// トラック一覧は開いたら再生中の曲が上の方に来るように送る
  void _setPanelOpen(bool open) {
    if (open == _panelOpen) return;
    setState(() => _panelOpen = open);
    if (!open || !_isPlaylist) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_trackListController.hasClients) return;
      final idx = ref.read(playlistPlayerProvider).currentTrackIndex ?? 0;
      final target = ((idx - 1) * TrackList.rowHeight)
          .clamp(0.0, _trackListController.position.maxScrollExtent);
      _trackListController.jumpTo(target);
    });
  }

  /// 開閉できるトラック一覧（動画の上に重ねるガラス板）
  Widget _buildTrackListPanel() => TrackListPanel(list: _buildTrackList());

  void _showMoreSheet() {
    final plState = ref.read(playlistPlayerProvider);
    PlayerMoreSheet.show(
      context,
      PlayerMoreSheet(
        firstVerseMode: plState.firstVerseMode,
        onToggleFirstVerse: _toggleFirstVerseMode,
        onToggleVolumeNorm: _toggleVolumeNorm,
        // AB 編集の UI は全画面には無い（横レイアウトの板）ので、全画面なら解除してから
        onEditAb: () {
          _exitFullscreen();
          _startPlaylistAbEdit();
        },
        onDjMix: () => DjMixSheet.show(context),
        hideVideo: _hideVideo,
        onHideVideoChanged: (v) => setState(() => _hideVideo = v),
      ),
    );
  }

  void _toggleShuffle() {
    ref.read(playlistPlayerProvider.notifier).toggleShuffle();
    _pendingJumpIndex = null;
    _cancelPreload();
    _preloadNextTrack();
  }

  void _cycleRepeatMode() {
    ref.read(playlistPlayerProvider.notifier).cycleRepeatMode();
    // プリロード済みの次曲が変わった場合のみ再プリロード
    // （_checkPreloadの定期チェックで自然に対応される）
    final nextIdx = ref.read(playlistPlayerProvider).peekNextTrackIndex();
    if (_preloadedTrackIndex != null && _preloadedTrackIndex != nextIdx) {
      _cancelPreload();
    }
  }

  void _toggleFirstVerseMode() {
    ref.read(playlistPlayerProvider.notifier).toggleFirstVerseMode();
    final plState = ref.read(playlistPlayerProvider);
    final track = plState.currentTrack;
    if (track != null && !track.hasRegion) {
      if (plState.firstVerseMode) {
        _applyFirstVerseCut(track);
      } else {
        _cancelFade();
        ref.read(loopProvider.notifier).reset();
      }
    }
  }

  void _toggleVolumeNorm() {
    final current = ref.read(volumeNormProvider);
    ref.read(volumeNormProvider.notifier).value = !current;
    final item = _isPlaylist
        ? ref.read(playlistPlayerProvider).currentTrack?.item
        : _currentItem;
    if (item == null) return;
    // オン: 測ってあれば即反映、無ければ波形を作り直して測る（できたときに反映）。
    // オフ: 100 に戻す（_normalizedVolume がオフなら 100 を返す）
    _applyVolumeNorm(item);
    if (!current && _normalizedVolume(item) == 100.0 && item.loudnessDb == null) {
      final source = ref.read(videoSourceProvider);
      if (source != null) _generateWaveform(source, item);
    }
  }

  void _seekTo(Duration time) => ref.read(playerProvider).seek(time);

  /// プレイリストモード（縦）: コントローラーに AB 編集ブロックを出す。
  /// 変更は即ループに反映され、「区間として登録」で LoopItem に残せる。
  /// B が無いときは曲末を B にして始める（ダイアログ時代と同じ）
  void _startPlaylistAbEdit() {
    final loop = ref.read(loopProvider);
    final notifier = ref.read(loopProvider.notifier);
    if (!loop.hasA) notifier.setPointA(Duration.zero);
    if (!loop.hasB) {
      final total = ref.read(playerProvider).state.duration;
      if (total > Duration.zero) notifier.setPointB(total);
    }
    setState(() {
      _editMode = true;
      _panelOpen = false;
    });
  }

  /// 現在のAB区間をLoopItemのリージョンとして保存
  Future<void> _saveCurrentAbAsRegion(int aMs, int bMs) async {
    final track = ref.read(playlistPlayerProvider).currentTrack;
    if (track == null) return;

    final item = track.item;
    final name = await _showRegionNameDialog('1番');
    if (name == null) return;

    final region = LoopRegion(
      id: IdGenerator.child(item.id, 'r'),
      name: name,
      pointAMs: aMs,
      pointBMs: bMs,
    );
    // 旧 AB 値しか無い曲なら先にそれを区間へ昇格させてから足す（他の画面と同じ経路）
    item.setRegions([...item.ensureRegions(), region]);
    await ref.read(loopItemsProvider.notifier).update(item);
    if (!mounted) return;

    // 現在のトラックをこの区間に切り替えるか確認
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('区間を登録しました'),
        content: Text('「$name」を登録しました。\nこのプレイリストの現在のトラックを、登録した区間に切り替えますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('登録のみ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('切り替える'),
          ),
        ],
      ),
    );

    if (replace == true && mounted) {
      // 現在のトラックのAB区間を登録した区間に切り替え
      final notifier = ref.read(loopProvider.notifier);
      notifier.setPointA(Duration(milliseconds: aMs));
      notifier.setPointB(Duration(milliseconds: bMs));
      if (!notifier.currentState.enabled) notifier.toggleEnabled();
      ref.read(playerProvider).seek(Duration(milliseconds: aMs));
    }
  }

}
