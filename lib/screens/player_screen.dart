import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../app.dart';
import '../core/constants.dart';
import '../core/tips.dart';
import '../core/utils/verse_detector.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/loop_state.dart';
import '../models/playlist_mode.dart' as pl;
import '../models/playlist_track.dart';
import '../models/tag.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_engine.dart';
import '../providers/playlist_player_provider.dart';
import '../services/cache_service.dart';
import '../services/export_service.dart';
import '../services/export_runner.dart';
import '../providers/subtitle_provider.dart';
import '../providers/thumb_tone_provider.dart';
import '../services/subtitle_service.dart';
import '../services/audio_analysis_service.dart';
import '../services/waveform_cache.dart';
import '../services/waveform_service.dart';
import '../services/youtube_service.dart';
import '../widgets/equalizer_icon.dart';
import '../widgets/glass_panel.dart';
import '../widgets/karaoke_subtitle.dart';
import '../widgets/lyrics_overlay.dart';
import '../widgets/item_tag_sheet.dart';
import '../widgets/marquee_text.dart';
import '../widgets/loop/ab_edit_controls.dart';
import '../widgets/loop/loop_panel_parts.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/player/now_playing_header.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/player_more_sheet.dart';
import '../widgets/player/player_status_views.dart';
import '../widgets/player/playlist_bottom_bar.dart';
import '../widgets/player/playlist_seek_area.dart';
import '../widgets/player/subtitle_toggle_button.dart';
import '../widgets/player/track_row_parts.dart';
import '../widgets/player/transition_stage.dart';
import '../widgets/player/video_player_widget.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/storage/app_boxes.dart';
import '../core/native_channels.dart';
import '../core/utils/id_generator.dart';
import '../core/ui/app_dialogs.dart';

/// 汎用プレーヤー画面。単体再生・プレイリスト再生・PiP対応。
/// ミニプレイヤー中に通知・PiPから届くメディア操作の受け口。
/// PlayerScreen の dispose 後に呼ばれるため、ref や mounted に依存しないこと。
class _MiniMediaCommands {
  _MiniMediaCommands({
    required this.playPause,
    required this.next,
    required this.prev,
  });

  final Future<void> Function() playPause;
  final void Function() next;
  final Future<void> Function() prev;
}

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
  final _loadingStatus = ValueNotifier<String>('準備中...');
  final _loadingProgress = ValueNotifier<double>(0);
  DateTime _lastStepTime = DateTime.now();
  String? _loadError;
  String? _cachedAudioPath;

  int _activeRegionIdx = -1;
  bool _compactSeekbar = false;

  // 横画面
  bool _isFullscreen = false;
  bool _showFullscreenOverlay = true;
  bool _showRightDrawer = false;
  Timer? _overlayHideTimer;
  bool _hideVideo = false;

  /// プレイリスト縦画面でトラック一覧を開いているか（ふだんは閉じている）
  bool _showTrackList = false;
  final _trackListController = ScrollController();
  bool _editMode = false;
  double _editStep = 0.1;
  int? _preloadingTargetIndex;

  // Preload state
  int? _preloadedTrackIndex;
  int? _pendingJumpIndex; // 手動選択時: 次の自動遷移でjumpToするインデックス
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

  /// 音量正規化の結果（正規化OFFなら100）。
  /// フェードイン/アウトはこの値を上限にする。100固定にすると
  /// フェード完了時に正規化した音量が上書きされてしまう。
  double _baseVolume = 100.0;

  bool _trackLoading = false;
  bool _loadingSnackShowing = false;
  final _tipNotifier = ValueNotifier<String>(getRandomTip());
  Timer? _tipTimer;

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

  /// ミニプレイヤー中に通知・PiPのボタンから呼ばれる操作。
  /// PlayerScreen の dispose 後も動く必要があるので ref/mounted に依存しない。
  _MiniMediaCommands? _miniCommands;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playerScreenActive = true;

    NativeChannels.pip.setMethodCallHandler((call) async {
      if (call.method == 'onPiPChanged') {
        ref.read(pipModeProvider.notifier).state = call.arguments as bool;
      } else if (call.method == 'onPiPAction') {
        switch (call.arguments) {
          case 'playPause':
            final player = ref.read(playerProvider);
            await player.playOrPause();
            // ユーザーの明示操作なので、復帰時の自動再開判定も追従させる
            _wasPlayingBeforePause = player.state.playing;
            _updatePiPPlayState();
          case 'next':
            if (_isPlaylist) _manualNext();
          case 'prev':
            if (_isPlaylist) _manualPrev();
        }
      } else if (call.method == 'onAudioDeviceChanged') {
        final device = call.arguments as String? ?? 'speaker';
        ref.read(audioDeviceProvider.notifier).state = device;
      } else if (call.method == 'onAudioNoisy') {
        // ヘッドホン抜き/Bluetooth切断 → 一時停止
        final player = ref.read(playerProvider);
        if (player.state.playing) {
          await player.pause();
        }
        // 復帰時にスピーカーから鳴り出さないよう自動再開を無効化
        _wasPlayingBeforePause = false;
      } else if (call.method == 'getPlayState') {
        return ref.read(playerProvider).state.playing;
      }
    });

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
        ref.read(loopProvider.notifier).setCurrentItem(_currentItem.id);
        _setupPlaylistCallbacks();
        NativeChannels.pip.invokeMethod('setAutoPiP', {
          'enabled': true, 'isPlaylist': _isPlaylist,
          'thumbnailUrl': _currentItem.thumbnailUrl,
          'thumbnailPath': _currentItem.thumbnailPath,
        }).catchError((_) {});
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
      NativeChannels.pip.invokeMethod('setAutoPiP', {
        'enabled': true, 'isPlaylist': _isPlaylist,
        'thumbnailUrl': _currentItem.thumbnailUrl,
        'thumbnailPath': _currentItem.thumbnailPath,
      }).catchError((_) {});
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
    _loadingProgress.dispose();
    _loadingStatus.dispose();
    _tipNotifier.dispose();
    _tipTimer?.cancel();
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
      NativeChannels.pip
          .invokeMethod('setAutoPiP', {'enabled': false}).catchError((_) {});
    }
    if (!miniActive) {
      try {
        ref.read(loopProvider.notifier).setCurrentItem(null);
        ref.read(playerAProvider).stop();
        ref.read(playerBProvider).stop();
        ref.read(loopProvider.notifier).onBPointReached = null;
        ref.read(loopProvider.notifier).onTrackEnd = null;
        if (_isPlaylist) ref.read(playlistPlayerProvider.notifier).clear();
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
      // 単体再生（プレイリストでない）では _miniCommands が無いので、
      // 再生/一時停止だけは直接プレイヤーを叩く
      final commands = _miniCommands;
      final engine = ref.read(playlistEngineProvider);
      final miniNotifier = ref.read(miniPlayerProvider.notifier);
      final audioDevice = ref.read(audioDeviceProvider.notifier);
      NativeChannels.pip.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'onPiPChanged':
            pipMode.state = call.arguments as bool;
          case 'onPiPAction':
            switch (call.arguments) {
              case 'playPause':
                if (commands != null) {
                  await commands.playPause();
                } else {
                  await engine.activePlayer.playOrPause();
                  _notifyPlayState(engine, miniNotifier);
                }
              case 'next':
                commands?.next();
              case 'prev':
                await commands?.prev();
            }
          case 'onAudioDeviceChanged':
            audioDevice.state = call.arguments as String? ?? 'speaker';
          case 'onAudioNoisy':
            // ヘッドホン抜き/Bluetooth切断 → 一時停止
            final player = engine.activePlayer;
            if (player.state.playing) await player.pause();
            _notifyPlayState(engine, miniNotifier);
          case 'getPlayState':
            return engine.activePlayer.state.playing;
        }
        return null;
      });
    } else {
      pipMode.state = false;
      NativeChannels.pip.setMethodCallHandler(null);
    }
    if (_cachedAudioPath != null) {
      try { File(_cachedAudioPath!).deleteSync(); } catch (_) {}
    }
    // ミニプレイヤー非アクティブならバックグラウンド再生停止
    if (!ref.read(miniPlayerProvider).active) {
      WakelockPlus.disable();
      NativeChannels.pip.invokeMethod('stopPlaybackService').catchError((_) {});
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

  /// 手動: トラック選択（パネルからタップ）
  Future<void> _selectTrack(int trackIndex) async {
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

      // 再生URIの解決（オフライン保存済みならローカル優先）はエンジンに集約
      final uri = await ref
          .read(playlistEngineProvider)
          .resolvePlayableUri(item)
          .timeout(const Duration(seconds: 30));
      if (uri == null) throw Exception('再生可能なストリームがありません');
      if (!mounted) return;

      await player
          .open(Media(uri), play: false)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      ref.read(videoSourceProvider.notifier).state = VideoSource(
        type: item.isYouTube
            ? VideoSourceType.youtube
            : VideoSourceType.local,
        uri: uri,
        title: item.title,
        videoId: item.videoId,
        thumbnailUrl: item.thumbnailUrl,
      );

      // プレイヤー使い回しのため、前トラックの速度が残らないよう毎回設定
      await player.setRate(item.speed);

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
    if (shouldFadeIn) {
      _startFadeIn();
    } else {
      // スワップ後のボリュームストリーム同期
      // （旧プレイヤーのフェードアウト値が残らないよう新プレイヤーに明示設定）
      try { ref.read(playerProvider).setVolume(_baseVolume); } catch (_) {}
    }
    _consecutiveLoadErrors = 0;
    // 字幕（プレイリスト曲切替時）: キャッシュSRT優先、無ければネット取得
    if (track.item.cachedSubtitlePath != null) {
      _loadCachedSubtitles(track.item);
    } else if (track.item.isYouTube &&
        track.item.videoId != null) {
      _fetchSubtitles(track.item.videoId!);
    } else {
      ref.read(subtitleDataProvider.notifier).state = null;
      ref.read(subtitleSubDataProvider.notifier).state = null;
    }
    // 2秒後に次曲プリロード開始（再生を安定させてから）
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isPreloading && _preloadedTrackIndex == null) {
        _preloadNextTrack();
      }
    });
  }

  void _loadTrackRegion(PlaylistTrack track) {
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
    final fadeSec = ref.read(crossfadeProvider);
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
          .prepare(ref.read(preloadPlayerProvider), nextTrack, isStale: isStale);

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

  /// 波形を先行生成してキャッシュに保存（fire-and-forget）
  Future<void> _preloadWaveform(
      PlaylistTrack track, StreamManifest? manifest, int gen) async {
    try {
      final item = track.item;
      final service = WaveformService();
      final onPcm = AudioAnalysisService.sinkFor(
          ref.read(loopItemsProvider.notifier), item);
      List<double>? waveform;

      // 保存済みの波形があれば音声 DL ごと省く（解析が必要なときは作り直す）
      if (onPcm == null) {
        waveform = await WaveformCache.load(item.id);
        if (waveform != null && waveform.isNotEmpty) {
          if (gen == _preloadGeneration) _waveformCache[item.id] = waveform;
          return;
        }
      }

      if (!item.isYouTube) {
        waveform =
            await service.generateForLocalFile(item.uri, 4000, onPcm: onPcm);
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
        if (gen == _preloadGeneration) _waveformCache[item.id] = waveform;
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

    // 動画ソースを先に更新しておく（スワップ前にUIが参照できるように）
    final item = newTrack.item;
    ref.read(videoSourceProvider.notifier).state = VideoSource(
      type: item.isYouTube
          ? VideoSourceType.youtube
          : VideoSourceType.local,
      uri: item.uri,
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
        _generateWaveform(source);
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  // --- Loading ---

  Future<void> _setProgress(double progress, String status) async {
    final elapsed = DateTime.now().difference(_lastStepTime).inMilliseconds;
    const minMs = 300;
    if (elapsed < minMs) {
      await Future.delayed(Duration(milliseconds: minMs - elapsed));
    }
    if (!mounted) return;
    _lastStepTime = DateTime.now();
    _loadingProgress.value = progress;
    _loadingStatus.value = status;
  }

  Future<void> _loadItem() async {
    _cancelFade();
    _loadingProgress.value = 0;
    _loadingStatus.value = '準備中...';
    setState(() {
      _loading = true;
      _loadError = null;
      _lastStepTime = DateTime.now();
      _activeRegionIdx = -1;
    });

    // Stop preload player to free resources
    try {
      ref.read(preloadPlayerProvider).stop();
    } catch (_) {}

    // Tip: 8秒ごとに自動切替
    _tipNotifier.value = getRandomTip();
    _tipTimer?.cancel();
    _tipTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _tipNotifier.value = getRandomTip();
    });

    // Reset player state
    ref.read(videoSourceProvider.notifier).state = null;
    ref.read(loopProvider.notifier).reset();
    ref.read(waveformDataProvider.notifier).state = null;

    try {
      final item = _currentItem;
      // オフラインキャッシュがあればローカルファイルを優先再生（通信不要）
      if (item.isYouTube &&
          CacheService.offlineVideoPath(item) != null) {
        await _loadCachedYouTube(item);
      } else if (item.isYouTube) {
        await _loadYouTube(item);
      } else {
        await _loadLocal(item);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '$e';
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

  /// 重い await の後に1フレーム描画の隙間を作る
  Future<void> _yieldFrame() =>
      Future.delayed(const Duration(milliseconds: 2));

  Future<void> _loadYouTube(LoopItem item) async {
    await _setProgress(0.15, 'ストリーム情報を解析中...');
    final ytService = ref.read(youtubeServiceProvider);
    final manifest =
        await ytService.getManifestWithFallback(item.videoId!);
    await _yieldFrame();

    if (!mounted) return;
    final streamUrl = YouTubeService.pickStreamUrl(manifest);

    final source = VideoSource(
      type: VideoSourceType.youtube,
      uri: streamUrl,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );

    if (!mounted) return;
    await _setProgress(0.50, 'プレーヤーを準備中...');
    final player = ref.read(playerProvider);
    await player
        .open(Media(source.uri), play: false)
        .timeout(const Duration(seconds: 60));

    // 波形用音声DLは再生開始後にバックグラウンドで実行→完了後に波形生成。
    // 波形が保存済み（かつ解析不要）なら DL せずにそのまま使う
    WaveformService.canSkipAudioFetch(item).then((skip) async {
      if (!mounted) return;
      if (skip) {
        _generateWaveform(source);
        return;
      }
      final path = await WaveformService().prefetchAudio(manifest, ytService);
      if (path == null || !mounted) return;
      _cachedAudioPath = path;
      _generateWaveform(source);
    });
    await _yieldFrame();
    ref.read(videoSourceProvider.notifier).state = source;

    await _finishLoading(item, source);
  }

  Future<void> _loadLocal(LoopItem item) async {
    await _setProgress(0.30, 'ファイルを読み込み中...');
    final source = VideoSource(
      type: VideoSourceType.local,
      uri: item.uri,
      title: item.title,
    );

    if (!mounted) return;
    await _setProgress(0.65, 'プレーヤーを準備中...');
    final player = ref.read(playerProvider);
    await player.open(Media(item.uri), play: false);
    await _yieldFrame();
    ref.read(videoSourceProvider.notifier).state = source;

    await _finishLoading(item, source);
  }

  /// オフラインキャッシュ済みのYouTube動画をローカルファイルから再生する。
  /// ソース種別はyoutubeのまま（字幕・UIロジックを流用）、Mediaだけローカルファイル。
  Future<void> _loadCachedYouTube(LoopItem item) async {
    await _setProgress(0.40, 'オフラインキャッシュを読み込み中...');
    final source = VideoSource(
      type: VideoSourceType.youtube,
      uri: item.cachedVideoPath!,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );

    if (!mounted) return;
    await _setProgress(0.70, 'プレーヤーを準備中...');
    final player = ref.read(playerProvider);
    await player.open(Media(item.cachedVideoPath!), play: false);
    await _yieldFrame();
    ref.read(videoSourceProvider.notifier).state = source;

    await _finishLoading(item, source);
  }

  Future<void> _finishLoading(LoopItem item, VideoSource source) async {
    if (!mounted) return;
    final player = ref.read(playerProvider);
    if (player.state.duration == Duration.zero) {
      await _setProgress(0.90, 'メタデータを取得中...');
      final prevVolume = player.state.volume;
      await player.setVolume(0);
      await player.play();
      for (var i = 0;
          i < 50 && player.state.duration == Duration.zero && mounted;
          i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await player.pause();
      await player.seek(Duration.zero);
      await player.setVolume(prevVolume);
      await _yieldFrame();
    }

    // Setup speed（プレイヤー使い回しのため毎回設定して前トラックの速度をリセット）
    player.setRate(item.speed);

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

    if (!mounted) return;
    await _setProgress(1.0, '読み込み完了！');
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    _tipTimer?.cancel();
    setState(() {
      _loading = false;
      _trackLoading = false;
    });
    _consecutiveLoadErrors = 0;

    // 再生カウント: 現在のアイテムを設定
    ref.read(loopProvider.notifier).setCurrentItem(item.id);

    // Auto-play + バックグラウンド再生サービス開始
    player.play();
    WakelockPlus.enable();
    NativeChannels.pip.invokeMethod('startPlaybackService', {
      'title': item.title,
      'thumbnailPath': item.thumbnailPath,
    }).catchError((_) {});

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

    // Waveform
    if (source.type == VideoSourceType.local || _cachedAudioPath != null) {
      _generateWaveform(source);
    }

    // 字幕: オフラインキャッシュがあればファイルから（通信不要）、無ければ取得
    if (item.cachedSubtitlePath != null) {
      _loadCachedSubtitles(item);
    } else if (source.type == VideoSourceType.youtube &&
        source.videoId != null) {
      _fetchSubtitles(source.videoId!);
    } else {
      ref.read(subtitleDataProvider.notifier).state = null;
    }
  }

  /// 保存済みSRTから字幕を読み込む（オフライン再生用）。
  Future<void> _loadCachedSubtitles(LoopItem item) async {
    ref.read(subtitleLoadingProvider.notifier).state = true;
    ref.read(subtitleDataProvider.notifier).state = null;
    ref.read(subtitleSubDataProvider.notifier).state = null;
    try {
      final file = File(item.cachedSubtitlePath!);
      if (!await file.exists()) {
        // ファイルが消えていればネットワーク取得にフォールバック
        if (mounted && item.videoId != null) {
          await _fetchSubtitles(item.videoId!);
        }
        return;
      }
      final subs = SubtitleService.parseSrt(await file.readAsString());
      if (!mounted) return;
      ref.read(subtitleDataProvider.notifier).state =
          subs.isNotEmpty ? subs : null;
      if (subs.isNotEmpty) {
        // オフライン用に明示保存した字幕はOFFのままだと見えないので自動表示
        if (ref.read(subtitleModeProvider) == SubtitleMode.off) {
          ref.read(subtitleModeProvider.notifier).state =
              SubtitleMode.subtitle;
        }
      }
    } catch (_) {
      if (mounted) ref.read(subtitleDataProvider.notifier).state = null;
    } finally {
      if (mounted) ref.read(subtitleLoadingProvider.notifier).state = false;
    }
  }

  Future<void> _fetchSubtitles(String videoId, {String? language}) async {
    ref.read(subtitleLoadingProvider.notifier).state = true;
    ref.read(subtitleDataProvider.notifier).state = null;
    ref.read(subtitleSubDataProvider.notifier).state = null;
    ref.read(subtitleSubLanguageProvider.notifier).state = null;
    try {
      final result = await SubtitleService.fetchSubtitles(
        videoId,
        preferredLanguage: language,
      );
      final subs = result.subs;
      if (mounted) {
        ref.read(subtitleDataProvider.notifier).state = subs;
        ref.read(subtitleTracksProvider.notifier).state = result.tracks;
        final hasSubs = subs != null && subs.isNotEmpty;
        if (hasSubs) {
          ref.read(subtitleLanguageProvider.notifier).state =
              result.selectedLanguage;
          // モードはユーザー選択を維持（デフォルトOFF）
        }
        final item = _currentItem;
        if (item.hasSubtitles == null || item.hasSubtitles != hasSubs) {
          item.hasSubtitles = hasSubs;
          ref.read(loopItemsProvider.notifier).update(item);
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        ref.read(subtitleLoadingProvider.notifier).state = false;
      }
    }
  }

  Future<void> _fetchSubSubtitle(SubtitleTrackInfo track) async {
    try {
      final subs = await SubtitleService.fetchTrack(track);
      if (mounted) {
        ref.read(subtitleSubDataProvider.notifier).state = subs;
        ref.read(subtitleSubLanguageProvider.notifier).state =
            track.languageCode;
      }
    } catch (_) {}
  }

  void _showSubtitleLanguagePicker() {
    final tracks = ref.read(subtitleTracksProvider);
    final mainLang = ref.read(subtitleLanguageProvider);
    final subLang = ref.read(subtitleSubLanguageProvider);
    if (tracks.isEmpty) return;

    String label(SubtitleTrackInfo t) =>
        t.languageName.isNotEmpty ? t.languageName : t.languageCode;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('字幕の言語',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              // メイン字幕
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xs),
                child: Text('メイン', style: Theme.of(context).textTheme.labelSmall!
                    .copyWith(color: AppTheme.accentGreen, fontWeight: FontWeight.bold)),
              ),
              for (final track in tracks)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.subtitles, size: AppIconSizes.sm),
                  title: Text(label(track)),
                  trailing: track.languageCode == mainLang
                      ? const Icon(Icons.check, color: AppTheme.accentGreen, size: AppIconSizes.sm)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    final videoId = _currentItem.videoId;
                    if (videoId != null) {
                      _fetchSubtitles(videoId, language: track.languageCode);
                    }
                  },
                ),
              const Divider(height: 1),
              // サブ字幕
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xs),
                child: Text('サブ（小さく表示）', style: Theme.of(context).textTheme.labelSmall!
                    .copyWith(color: Colors.grey)),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.subtitles_off, size: AppIconSizes.sm),
                title: const Text('なし'),
                trailing: subLang == null
                    ? const Icon(Icons.check, color: Colors.grey, size: AppIconSizes.sm)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(subtitleSubDataProvider.notifier).state = null;
                  ref.read(subtitleSubLanguageProvider.notifier).state = null;
                },
              ),
              for (final track in tracks)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.subtitles, size: AppIconSizes.sm),
                  title: Text(label(track)),
                  trailing: track.languageCode == subLang
                      ? const Icon(Icons.check, color: Colors.grey, size: AppIconSizes.sm)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _fetchSubSubtitle(track);
                  },
                ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
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

  /// 現在のループ状態を選択中の区間に同期
  void _syncRegionFromLoop() {
    if (_isPlaylist || _activeRegionIdx < 0) return;
    // その場で書き換えるので、表示用のコピーではなく本体リストを取る
    final regions = _currentItem.ensureRegions();
    if (_activeRegionIdx >= regions.length) return;
    final loop = ref.read(loopProvider);
    regions[_activeRegionIdx] = regions[_activeRegionIdx].copyWith(
      pointAMs: () => loop.pointA?.inMilliseconds,
      pointBMs: () => loop.pointB?.inMilliseconds,
    );
  }

  /// 区間の変更をLoopItemに保存
  Future<void> _saveRegions() async {
    if (_isPlaylist) return;
    final item = _currentItem;
    // effectiveRegionsではなくregionsを直接参照（レガシーAB値の誤復元を防止）
    if (item.regions.isNotEmpty) {
      item.pointAMs = item.regions.first.pointAMs ?? 0;
      item.pointBMs = item.regions.first.pointBMs ?? 0;
    } else {
      item.pointAMs = 0;
      item.pointBMs = 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
  }

  void _addRegion() {
    if (_isPlaylist) return;
    final regions = _currentItem.ensureRegions();
    if (regions.length >= _maxRegions) return;

    _syncRegionFromLoop();
    final position = ref.read(playerProvider).state.position;
    final region = LoopRegion(
      id: IdGenerator.next(),
      name: '区間 ${regions.length + 1}',
      pointAMs: position.inMilliseconds,
      pointBMs: null,
    );
    regions.add(region);
    _currentItem.regions = List.from(regions);

    setState(() {
      _activeRegionIdx = regions.length - 1;
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
    setState(() {
      regions[index] = regions[index].copyWith(name: name);
      _currentItem.regions = List.from(regions);
    });
    _saveRegions();
  }

  void _deleteRegion(int index) {
    final regions = _currentItem.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    setState(() {
      regions.removeAt(index);
      _currentItem.regions = List.from(regions);
      if (_activeRegionIdx >= regions.length) {
        _activeRegionIdx = regions.isEmpty ? -1 : regions.length - 1;
      }
      if (regions.isEmpty) _editMode = false;
    });
    if (_activeRegionIdx >= 0) {
      _loadRegion(regions[_activeRegionIdx]);
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
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('リネーム'),
              onTap: () {
                Navigator.pop(ctx);
                _renameRegion(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('削除',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteRegion(index);
              },
            ),
          ],
        ),
      ),
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
      await NativeChannels.pip.invokeMethod('enterPiP', {
        'thumbnailUrl': _currentItem.thumbnailUrl,
        'thumbnailPath': _currentItem.thumbnailPath,
      });
    } catch (e) {
      debugPrint('enterPiP failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.info('PiPに入れませんでした'),
        );
      }
    }
  }

  void _updatePiPPlayState() {
    final playing = ref.read(playerProvider).state.playing;
    NativeChannels.pip
        .invokeMethod('updatePiPPlayState', {'playing': playing}).catchError((_) {});
  }

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

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(fullTrack ? '全体を書き出し' : '区間を書き出し'),
        content: Text(subtitle, style: Theme.of(ctx).textTheme.bodyMedium),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _executeExport(true, fullTrack: fullTrack);
            },
            icon: const Icon(Icons.audiotrack, size: AppIconSizes.s),
            label: const Text('音声のみ'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _executeExport(false, fullTrack: fullTrack);
            },
            icon: const Icon(Icons.videocam, size: AppIconSizes.s),
            label: const Text('MP4'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeExport(bool audioOnly,
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
    await runExportFlow(
      context,
      inputUri: inputUri,
      startMs: startMs,
      endMs: endMs,
      format: audioOnly ? ExportFormat.audioOnly : ExportFormat.mp4,
      title: _currentItem.title,
    );
  }

  // --- Waveform ---

  void _retryWaveform() {
    final source = ref.read(videoSourceProvider);
    if (source != null) _generateWaveform(source);
  }

  Future<void> _generateWaveform(VideoSource source) async {
    ref.read(waveformDataProvider.notifier).state = null;
    ref.read(waveformErrorProvider.notifier).state = null;
    ref.read(waveformLoadingProvider.notifier).state = true;
    try {
      final service = WaveformService();
      await service.cancel();

      if (source.type != VideoSourceType.local && source.videoId == null) {
        return;
      }
      // 先読み済みの音声があればDLを省略する
      final prefetched = _cachedAudioPath;
      _cachedAudioPath = null;
      final waveform = await service.generateForVideoSource(
        source,
        ref.read(youtubeServiceProvider),
        cachedAudioPath: prefetched,
        // 未解析ならテンポ/キー解析をデコードに相乗りさせる
        onPcm: AudioAnalysisService.sinkFor(
            ref.read(loopItemsProvider.notifier), _currentItem),
        cacheKey: _currentItem.id,
      );

      if (mounted) {
        if (waveform == null || waveform.isEmpty) {
          ref.read(waveformErrorProvider.notifier).state = '波形取得失敗';
        } else {
          ref.read(waveformDataProvider.notifier).state = waveform;
          // 波形キャッシュに保存し、1番だけモードの切断点を再計算
          _waveformCache[_currentItem.id] = waveform;
          if (_isPlaylist) {
            final track =
                ref.read(playlistPlayerProvider).currentTrack;
            if (track != null && !track.hasRegion) {
              _applyFirstVerseCut(track);
            }
          }
          // 音量正規化
          _applyVolumeNormalization(waveform);
        }
      }
    } catch (e) {
      if (mounted) {
        ref.read(waveformErrorProvider.notifier).state = '$e';
      }
    } finally {
      if (mounted) {
        ref.read(waveformLoadingProvider.notifier).state = false;
      }
    }
  }

  /// 波形データから音量を正規化（デフォルト50を基準に調整）
  void _applyVolumeNormalization(List<double> waveform) {
    if (!ref.read(volumeNormProvider)) {
      _baseVolume = 100.0;
      return;
    }

    // 波形のRMS（二乗平均平方根）を計算
    var sumSquares = 0.0;
    for (final v in waveform) {
      sumSquares += v * v;
    }
    final rms = math.sqrt(sumSquares / waveform.length);
    if (rms <= 0) return;

    // 基準RMS: 0.25（正規化済み波形の中央値想定）
    const targetRms = 0.25;
    final ratio = targetRms / rms;

    // 音量 = 50 * ratio（20〜100にクランプ）
    final volume = (50.0 * ratio).clamp(20.0, 100.0);
    _baseVolume = volume;
    try {
      ref.read(playerProvider).setVolume(volume);
    } catch (_) {}
  }



  // --- Track context menu ---

  void _showTrackMenu(int trackIndex, PlaylistTrack track) {
    final isCurrent =
        ref.read(playlistPlayerProvider).currentTrackIndex == trackIndex;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
              child: Text(
                track.displayName,
                style: Theme.of(ctx).textTheme.titleSmall!.copyWith(fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            if (!isCurrent)
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('この曲にスキップ'),
                onTap: () {
                  Navigator.pop(ctx);
                  _selectTrack(trackIndex);
                },
              ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('タグを編集'),
              onTap: () {
                Navigator.pop(ctx);
                _showTrackTagEditor(track);
              },
            ),
            if (widget.playlistId != null)
              ListTile(
                leading:
                    const Icon(Icons.playlist_remove, color: Colors.redAccent),
                title: const Text('プレイリストから削除',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeTrackFromPlaylist(trackIndex, track);
                },
              ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  void _showTrackTagEditor(PlaylistTrack track) {
    final tags = ref.read(tagsProvider);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ItemTagSheet(
        tags: tags,
        item: track.item,
        onToggle: (tagId, add) async {
          if (add) {
            await ref
                .read(loopItemsProvider.notifier)
                .addTagToItems([track.item.id], tagId);
          } else {
            await ref
                .read(loopItemsProvider.notifier)
                .removeTagFromItems([track.item.id], tagId);
          }
        },
        onCreateAndAdd: (name) async {
          final tag = await ref.read(tagsProvider.notifier).create(name);
          await ref
              .read(loopItemsProvider.notifier)
              .addTagToItems([track.item.id], tag.id);
          return tag;
        },
      ),
    );
  }

  void _removeTrackFromPlaylist(int trackIndex, PlaylistTrack track) async {
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

  /// 通常の行の高さ（itemExtent で固定し、開いたときに再生中の行まで送れるようにする）
  static const _trackRowHeight = 64.0;

  /// 曲リストの中身（背景なし）。
  /// - 縦画面: ガラス板の一覧パネルの中に入る。行の高さは固定
  /// - transparent: 横画面ドロワー用。行を詰める
  Widget _buildPlaylistPanel(double bottomInset, {bool transparent = false}) {
    final plState = ref.watch(playlistPlayerProvider);
    final currentIdx = plState.currentTrackIndex;
    final allTags = ref.watch(tagsProvider);
    final tagMap = {for (final t in allTags) t.id: t};
    // タグ変更時にトラック一覧を再描画するために監視
    ref.watch(loopItemsProvider);

    return ListView.builder(
      controller: transparent ? null : _trackListController,
      itemExtent: transparent ? null : _trackRowHeight,
      padding: EdgeInsets.only(
          bottom: bottomInset + (transparent ? AppSpacing.xxl : AppSpacing.md)),
      itemCount: plState.tracks.length,
      itemBuilder: (ctx, i) => _buildTrackRow(
        ctx,
        i,
        plState.tracks[i],
        tagMap,
        isCurrent: i == currentIdx,
        isPreloading: _preloadingTargetIndex == i,
        isPreloaded: _preloadedTrackIndex == i,
        dense: transparent,
      ),
    );
  }

  /// 曲リストの1行: 状態 / サムネ / タイトル + BPM・キー・区間 / タグ。
  /// 再生中は緑の薄い帯、プリロード済みは「次」バッジ
  Widget _buildTrackRow(
    BuildContext ctx,
    int i,
    PlaylistTrack track,
    Map<String, Tag> tagMap, {
    required bool isCurrent,
    required bool isPreloading,
    required bool isPreloaded,
    required bool dense,
  }) {
    final textTheme = Theme.of(ctx).textTheme;

    final Widget status;
    if (isCurrent) {
      status = const EqualizerIcon(color: AppTheme.accentGreen, size: 18);
    } else if (isPreloading) {
      status = const SizedBox(
        width: AppIconSizes.s,
        height: AppIconSizes.s,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
      );
    } else if (isPreloaded) {
      status = const Icon(Icons.check_circle_outline,
          color: AppTheme.accentGreen, size: AppIconSizes.sm);
    } else {
      status = Text('${i + 1}',
          style: textTheme.labelSmall, textAlign: TextAlign.center);
    }

    final titleStyle = textTheme.bodyMedium!.copyWith(
      fontSize: dense ? 13 : 14,
      fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
      color: isCurrent
          ? AppTheme.accentGreen
          : track.enabled
              ? null
              : Colors.grey,
    );

    final item = track.item;
    final subParts = <String>[
      if (item.bpm != null) '${item.bpm!.round()} BPM',
      if (item.musicalKey != null) item.musicalKey!,
      if (track.hasRegion)
        '${TimeUtils.formatShortMs(track.startMs)} - ${TimeUtils.formatShortMs(track.endMs)}',
    ];

    return InkWell(
      onTap: () => _selectTrack(i),
      onLongPress: () => _showTrackMenu(i, track),
      child: Container(
        decoration: BoxDecoration(
          color: isCurrent ? AppTheme.accentGreen.withValues(alpha: 0.12) : null,
          border: Border(
            top: BorderSide(
                color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.06)),
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.lg + 2,
          vertical: dense ? AppSpacing.sm : AppSpacing.md + 2,
        ),
        child: Row(
          children: [
            SizedBox(width: AppIconSizes.lg, child: Center(child: status)),
            const SizedBox(width: AppSpacing.md),
            TrackThumb(
              track: track,
              width: dense ? 48 : 60,
              height: dense ? 36 : 44,
            ),
            const SizedBox(width: AppSpacing.md + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 再生中: マーキー、それ以外: 通常テキスト
                  if (isCurrent)
                    MarqueeText(text: track.displayName, style: titleStyle)
                  else
                    Text(
                      track.displayName,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (subParts.isNotEmpty || isPreloaded) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            subParts.join('  ·  '),
                            style: textTheme.labelSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isPreloaded) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.accentGreen.withValues(alpha: 0.18),
                              borderRadius: AppRadius.borderXs,
                            ),
                            child: Text(
                              '次',
                              style: textTheme.labelSmall!.copyWith(
                                  fontSize: 9, color: AppTheme.accentGreen),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // タグ: 右端に配置
            ...trackTagChips(ctx, track, tagMap),
          ],
        ),
      ),
    );
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    // 再生状態の同期: PiP + 通知コントローラー
    ref.listen(playingProvider, (_, next) {
      final playing = next.valueOrNull ?? false;
      NativeChannels.pip.invokeMethod(
          'updatePiPPlayState', {'playing': playing}).catchError((_) {});
      NativeChannels.pip.invokeMethod('updatePlaybackService', {
        'title': _currentItem.title,
        'playing': playing,
        'thumbnailPath': _currentItem.thumbnailPath,
      }).catchError((_) {});
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

    // プレイリスト縦画面はガラス風: AppBar を透明にして背景を上まで通し、
    // 曲名は動画の下に出すので AppBar にはプレイリスト名だけ
    final glassLook =
        _isPlaylist && !_loading && _loadError == null && !isLandscape;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _activateMiniPlayer();
      },
      child: Scaffold(
      extendBodyBehindAppBar: glassLook,
      appBar: isLandscape
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
        actions: [
          // 字幕モード切替（タップ: OFF→カラオケ→リリクス→OFF、長押し: 言語選択）
          SubtitleToggleButton(onLongPress: _showSubtitleLanguagePicker),
          if (Platform.isAndroid || Platform.isIOS)
            IconButton(
              icon: const Icon(Icons.picture_in_picture_alt, size: AppIconSizes.ml),
              onPressed: _enterPiP,
              tooltip: 'ピクチャーインピクチャー',
            ),
        ],
      ),
      body: _loading
          ? PlayerLoadingView(
              title: _currentItem.title,
              progress: _loadingProgress,
              status: _loadingStatus,
              tip: _tipNotifier,
            )
          : _loadError != null
              ? PlayerErrorView(
                  message: _loadError!,
                  stoppedByRepeatedErrors: _isPlaylist &&
                      _consecutiveLoadErrors >= _maxConsecutiveErrors,
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
                )
              : _buildPlayerView(bottomInset),
    ),
    );
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

    // プレイリストモード: dispose後も動くコールバックを設定
    if (_isPlaylist) {
      _setupMiniPlayerCallbacks();
    }
  }

  /// ミニプレイヤー用のコールバック（PlayerScreen dispose後も動作する）。
  ///
  /// 遷移の機構（URL解決・プリロード・スロット入替・区間適用）は PlaylistEngine に
  /// 集約してあり、PlayerScreen 側のコールバックと同じ実装を通る。
  /// ここに組み立てるのは「画面が無いときの振る舞い」だけ。
  void _setupMiniPlayerCallbacks() {
    // dispose後にref.read()は使えないため、providerコンテナに生き続ける
    // エンジンとNotifierを事前にキャプチャしておく
    final engine = ref.read(playlistEngineProvider);
    final loopNotifier = ref.read(loopProvider.notifier);
    final plNotifier = ref.read(playlistPlayerProvider.notifier);
    final miniNotifier = ref.read(miniPlayerProvider.notifier);

    int? preloadedIdx;
    var isPreloading = false;
    DateTime? lastReplayAt;

    /// 次トラックをプリロードプレイヤーに読み込む
    Future<void> preloadNext() async {
      if (isPreloading || preloadedIdx != null) return;
      final ps = plNotifier.currentState;
      final nextIdx = ps.peekNextTrackIndex();
      if (nextIdx == null) return;
      final nextTrack = ps.tracks[nextIdx];
      final current = ps.currentTrack;
      // 同一アイテムは遷移時のシークだけで済むためプリロード不要
      if (current != null && nextTrack.isSameItem(current)) return;

      isPreloading = true;
      try {
        await engine.prepare(engine.preloadPlayer, nextTrack);
        preloadedIdx = nextIdx;
        engine.armCrossfade(nextTrack);
      } catch (e) {
        debugPrint('[MiniPlayer] プリロード失敗: $e');
      } finally {
        isPreloading = false;
      }
    }

    /// プリロード済みプレイヤーにスワップして再生開始
    void swapToPreloaded(PlaylistTrack track) {
      preloadedIdx = null;
      engine.swapSlots();
      engine.applyRegion(track);
      loopNotifier.setCurrentItem(track.item.id);
      miniNotifier.updateCurrentItem(track.item,
          trackIndex: plNotifier.currentState.currentTrackIndex);
      // 次のプリロードを開始
      preloadNext();
    }

    /// 同一アイテムの別区間にシーク
    void seekToTrack(PlaylistTrack track) {
      if (track.startMs != null) {
        engine.activePlayer.seek(Duration(milliseconds: track.startMs!));
      }
      engine.applyRegion(track);
      miniNotifier.updateCurrentItem(track.item,
          trackIndex: plNotifier.currentState.currentTrackIndex);
    }

    /// 未準備のまま曲が終わった場合に、同じ曲を頭からやり直して再生を止めない。
    /// タイマーとcompletedの二重発火や極短トラックでの連続やり直しで
    /// フリーズしないよう1秒間は抑制する。
    void replayCurrent() {
      final now = DateTime.now();
      if (lastReplayAt != null &&
          now.difference(lastReplayAt!) <= const Duration(seconds: 1)) {
        return;
      }
      lastReplayAt = now;
      try {
        engine.activePlayer
          ..seek(Duration.zero)
          ..play();
      } catch (_) {}
    }

    void advance(AdvanceReadiness readiness) {
      final changed = plNotifier.next();
      if (!changed) return;
      final track = plNotifier.currentState.currentTrack;
      if (track == null) return;
      if (readiness == AdvanceReadiness.sameItem) {
        seekToTrack(track);
      } else {
        swapToPreloaded(track);
      }
    }

    loopNotifier.onBPointReached = () {
      if (plNotifier.currentState.repeatMode == pl.RepeatMode.single) {
        return false;
      }
      final readiness = engine.readiness(preloadedIndex: preloadedIdx);
      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        advance(readiness);
        return true;
      }
      // 未準備 → ABループ継続、裏でプリロードを確保
      if (readiness == AdvanceReadiness.notReady && !isPreloading) {
        preloadNext();
      }
      return false;
    };

    loopNotifier.onTrackEnd = () {
      final readiness = engine.readiness(preloadedIndex: preloadedIdx);
      if (readiness == AdvanceReadiness.sameItem ||
          readiness == AdvanceReadiness.preloaded) {
        advance(readiness);
      } else if (readiness == AdvanceReadiness.notReady) {
        replayCurrent();
        if (!isPreloading) preloadNext();
      }
    };

    /// 同一アイテムでない前トラックをアクティブプレイヤーに直接読み込む
    Future<void> loadPrev() async {
      final ps = plNotifier.currentState;
      final prevIdx = ps.peekPrevTrackIndex();
      if (prevIdx == null) return;
      final prevTrack = ps.tracks[prevIdx];
      final current = ps.currentTrack;
      if (current != null && prevTrack.isSameItem(current)) {
        if (!plNotifier.prev()) return;
        final track = plNotifier.currentState.currentTrack;
        if (track != null) seekToTrack(track);
        return;
      }
      try {
        await engine.prepare(engine.activePlayer, prevTrack);
        plNotifier.jumpTo(prevIdx);
        final track = plNotifier.currentState.currentTrack;
        if (track == null) return;
        engine.activePlayer.play();
        engine.applyRegion(track);
        loopNotifier.setCurrentItem(track.item.id);
        miniNotifier.updateCurrentItem(track.item,
            trackIndex: plNotifier.currentState.currentTrackIndex);
        preloadedIdx = null;
        preloadNext();
      } catch (e) {
        debugPrint('[MiniPlayer] 前トラックの読み込みに失敗: $e');
      }
    }

    // 通知・PiPのボタンから使う操作（PlayerScreen dispose後も動く）
    _miniCommands = _MiniMediaCommands(
      playPause: () async {
        await engine.activePlayer.playOrPause();
        _notifyPlayState(engine, miniNotifier);
      },
      next: () {
        final readiness = engine.readiness(preloadedIndex: preloadedIdx);
        if (readiness == AdvanceReadiness.none) return;
        if (readiness == AdvanceReadiness.notReady) {
          if (!isPreloading) preloadNext();
          return;
        }
        advance(readiness);
      },
      prev: loadPrev,
    );

    // 初回プリロード開始
    preloadNext();
  }

  /// 再生状態をPiPと通知に伝える。
  ///
  /// ミニプレイヤー中は ref が使えないので engine と notifier を受け取る。
  /// ネイティブ側の updatePlaybackService はタイトル未指定だと「再生中」に
  /// 上書きしてしまうため、曲名は毎回渡すこと。
  static void _notifyPlayState(
      PlaylistEngine engine, MiniPlayerNotifier miniNotifier) {
    final playing = engine.activePlayer.state.playing;
    final item = miniNotifier.currentState.item;
    NativeChannels.pip
        .invokeMethod('updatePiPPlayState', {'playing': playing})
        .catchError((_) {});
    NativeChannels.pip.invokeMethod('updatePlaybackService', {
      'title': item?.title ?? '再生中',
      'playing': playing,
      'thumbnailPath': item?.thumbnailPath,
    }).catchError((_) {});
  }

  // （旧 _smoothNext / _smoothPrev は _manualNext / _manualPrev に統合済み）

  // =====================================================================
  // 横画面レイアウト
  // =====================================================================

  void _enterFullscreen() {
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    if (isPortrait) {
      // 縦→横回転してフルスクリーン
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    setState(() {
      _isFullscreen = true;
      _showFullscreenOverlay = true;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _resetOverlayTimer();
  }

  void _exitFullscreen() {
    setState(() {
      _isFullscreen = false;
      _showRightDrawer = false;
    });
    _overlayHideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 縦に戻す → 少し待ってから全方向許可に戻す
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    Future.delayed(const Duration(milliseconds: 500), () {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    });
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

  /// 横画面 右ドロワーパネル（モード別）
  Widget _buildLandscapeRightPanel(double bottomInset) {
    if (_isPlaylist) {
      return Column(
        children: [
          _buildPlaylistControls(),
          Expanded(child: _buildPlaylistPanel(bottomInset, transparent: true)),
        ],
      );
    }

    // 単体再生: 横画面専用レイアウト（縦にフル活用）
    final regions = _currentItem.effectiveRegions;
    final loop = ref.watch(loopProvider);
    final notifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Column(
      children: [
        // ループON/OFF + 編集ボタン
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          child: Row(
            children: [
              SizedBox(
                height: 28,
                child: FilledButton.icon(
                  onPressed: hasSource
                      ? () => notifier.toggleEnabled()
                      : null,
                  icon: Icon(
                    loop.enabled ? Icons.repeat_on : Icons.repeat,
                    size: AppIconSizes.s,
                  ),
                  label: Text(loop.enabled ? 'ON' : 'OFF'),
                  style: FilledButton.styleFrom(
                    backgroundColor: loop.enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    foregroundColor: loop.enabled
                        ? Colors.black
                        : Colors.grey,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                  ),
                ),
              ),
              const Spacer(),
              if (_activeRegionIdx >= 0)
                SizedBox(
                  height: 26,
                  child: TextButton.icon(
                    onPressed: _editMode
                        ? _finishEdit
                        : () => setState(() => _editMode = true),
                    icon: Icon(
                      _editMode ? Icons.check : Icons.edit,
                      size: AppIconSizes.xs,
                      color: _editMode ? AppTheme.accentGreen : Colors.grey,
                    ),
                    label: Text(
                      _editMode ? '保存' : '編集',
                      style: textTheme.labelSmall!.copyWith(
                        color: _editMode ? AppTheme.accentGreen : Colors.grey,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              SizedBox(
                height: 26,
                child: OutlinedButton.icon(
                  onPressed: () => _showExportDialog(
                      fullTrack: !loop.hasBothPoints),
                  icon: const Icon(Icons.file_download_outlined,
                      size: AppIconSizes.xs),
                  label: Text('書出し', style: textTheme.labelSmall),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.grey.shade700),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 区間リスト（Expandedでフル利用）
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            children: [
              RegionTile(
                name: '全体',
                isActive: _activeRegionIdx == -1,
                pointAMs: null,
                pointBMs: null,
                onTap: _clearRegion,
              ),
              Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
              for (var i = 0; i < regions.length; i++) ...[
                RegionTile(
                  name: regions[i].name,
                  isActive: i == _activeRegionIdx,
                  pointAMs: regions[i].pointAMs,
                  pointBMs: regions[i].pointBMs,
                  onTap: () => _selectRegion(i),
                  onLongPress: () => _showRegionMenu(i),
                ),
                if (i < regions.length - 1)
                  Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
              ],
              const SizedBox(height: AppSpacing.sm),
              if (regions.length < _maxRegions)
                SizedBox(
                  width: double.infinity,
                  height: 28,
                  child: OutlinedButton.icon(
                    onPressed: _addRegion,
                    icon: const Icon(Icons.add, size: AppIconSizes.xs),
                    label: Text('区間追加', style: textTheme.labelSmall),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.grey.shade700),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // ABコントロール（選択中の区間）
        if (_activeRegionIdx >= 0) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: _editMode
                ? AbEditControls(
                    loop: loop,
                    notifier: notifier,
                    step: _editStep,
                    onStepChanged: (s) => setState(() => _editStep = s),
                    onSeek: _seekTo,
                    compact: true,
                    onSetA: hasSource
                        ? () => notifier.setPointA(
                            ref.read(playerProvider).state.position)
                        : null,
                    onSetB: hasSource
                        ? () => notifier.setPointB(
                            ref.read(playerProvider).state.position)
                        : null,
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LoopPointDisplay(
                          label: 'A',
                          color: AppTheme.pointAColor,
                          time: loop.pointA,
                          onSeek: _seekTo),
                      const SizedBox(height: AppSpacing.sm),
                      LoopPointDisplay(
                          label: 'B',
                          color: AppTheme.pointBColor,
                          time: loop.pointB,
                          onSeek: _seekTo),
                    ],
                  ),
          ),
        ],
      ],
    );
  }

  /// 字幕モード切替ボタン（タップ: OFF→カラオケ→リリクス→OFF、長押し: 言語選択）。
  /// 縦画面コントロールと横全画面トップバーで共用。
  /// 横画面 全画面モード
  Widget _buildFullscreenView(double bottomInset) {
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.4;
    // immersive中はSafeAreaのpaddingが0になるため、viewPadding(ノッチ/ジェスチャー
    // 領域などの物理インセット)を明示的に使う。最低マージンも確保。
    final vp = MediaQuery.viewPaddingOf(context);
    double atLeast(double v, double m) => v > m ? v : m;
    final padL = atLeast(vp.left, 12);
    final padR = atLeast(vp.right, 12);
    // 開閉タブはコントロール表示に同調（常時表示は邪魔）。ただしドロワーを開いて
    // いる間は閉じられるよう表示し続ける。
    final showToggle = _showFullscreenOverlay || _showRightDrawer;
    return Stack(
      children: [
        // 動画（全画面）+ タップ検知を上に被せる
        const Positioned.fill(
          child: VideoPlayerWidget(useAspectRatio: false),
        ),
        // リリクスオーバーレイ（動画上に重ねる）
        const Positioned.fill(child: LyricsOverlay()),
        // タップ検知レイヤー（リリクス非表示時のみ有効）
        Positioned.fill(
          child: Consumer(builder: (_, ref, _) {
            final mode = ref.watch(subtitleModeProvider);
            if (mode == SubtitleMode.lyrics) return const SizedBox.shrink();
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleFullscreenOverlay,
              onDoubleTap: _exitFullscreen,
            );
          }),
        ),
          // オーバーレイ（コントロール）
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: _showFullscreenOverlay ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: IgnorePointer(
                ignoring: !_showFullscreenOverlay,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black54,
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black54,
                      ],
                      stops: [0.0, 0.2, 0.7, 1.0],
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: padL,
                      right: padR,
                      top: atLeast(vp.top, 8),
                      bottom: atLeast(vp.bottom, 12),
                    ),
                    child: Column(
                      children: [
                        // 上部バー（タイトル + 字幕切替）
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _isPlaylist
                                    ? (ref.read(playlistPlayerProvider)
                                            .currentTrack
                                            ?.displayName ??
                                        _currentItem.title)
                                    : _currentItem.title,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyLarge!
                                    .copyWith(color: Colors.white),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SubtitleToggleButton(onLongPress: _showSubtitleLanguagePicker),
                          ],
                        ),
                        const Spacer(),
                        // 下部コントロール
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LoopSeekbar(
                              compact: true,
                              allowMarkerDrag: false,
                              onRetryWaveform: _retryWaveform,
                            ),
                            const PlayerControls(),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 字幕（カラオケ）: コントロールの自動非表示に関わらず常時表示。
          // コントロール表示中はシークバーより上、非表示中は画面下寄りに移動。
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: padL,
            right: padR,
            bottom: (_showFullscreenOverlay ? 132.0 : 32.0) + bottomInset,
            child: const IgnorePointer(child: KaraokeSubtitle()),
          ),
          // 右ドロワー（半透明）
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            right: _showRightDrawer ? 0 : -drawerWidth,
            top: 0,
            bottom: 0,
            width: drawerWidth,
            child: GestureDetector(
              onTap: () {}, // タップ透過防止
              child: Material(
                color: Theme.of(context)
                    .scaffoldBackgroundColor
                    .withValues(alpha: 0.75),
                elevation: 8,
                child: Theme(
                  data: Theme.of(context).copyWith(
                    cardTheme: CardThemeData(
                      color: Colors.transparent,
                      elevation: 0,
                    ),
                  ),
                  child: _buildLandscapeRightPanel(bottomInset),
                ),
              ),
            ),
          ),
          // ドロワー開閉タブ（コントロール表示に同調。右端はノッチ分内側へ）
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            right: _showRightDrawer ? drawerWidth : vp.right,
            top: 0,
            bottom: 0,
            child: Center(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: showToggle ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !showToggle,
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _showRightDrawer = !_showRightDrawer);
                    },
                    child: Container(
                      width: 24,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.7),
                        borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(8)),
                      ),
                      child: Icon(
                        _showRightDrawer
                            ? Icons.chevron_right
                            : Icons.chevron_left,
                        color: Colors.white,
                        size: AppIconSizes.sm,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // フルスクリーン解除ボタン（右下、フルスクリーンボタンと同じ位置）
          if (_showFullscreenOverlay)
            Positioned(
              right: 12 + padR,
              bottom: 12 + vp.bottom,
              child: GestureDetector(
                onTap: _exitFullscreen,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: AppRadius.borderXs,
                  ),
                  child: const Icon(Icons.fullscreen_exit,
                      color: Colors.white, size: AppIconSizes.lg),
                ),
              ),
            ),
        ],
      );
  }

  /// 画面の向きに合わせてフルスクリーン状態を切り替える。
  /// build から直接呼ぶとフレームの整合が崩れる（フィールド書き換え・SystemChrome呼び出し・
  /// タイマー起動が副作用として走る）ため、必ずフレーム後に呼ぶこと。
  void _syncFullscreenTo(bool fullscreen) {
    if (!mounted || fullscreen == _isFullscreen) return;
    if (fullscreen) {
      _isFullscreen = true;
      _showFullscreenOverlay = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _resetOverlayTimer();
    } else {
      _isFullscreen = false;
      _showRightDrawer = false;
      _overlayHideTimer?.cancel();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    setState(() {});
  }

  Widget _buildPlayerView(double bottomInset) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // 横画面 = フルスクリーン、縦に戻ったら自動解除。
    // 状態の反映はフレーム後（buildは表示するものを決めるだけにする）
    if (isLandscape != _isFullscreen) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _syncFullscreenTo(isLandscape));
    }
    if (isLandscape) return _buildFullscreenView(bottomInset);

    final regions = _currentItem.effectiveRegions;
    final loop = ref.watch(loopProvider);

    // プレイリスト: サムネ色の背景の上に、角丸の動画・曲名・（開いていれば）トラック一覧・
    // ガラス板のコントローラー。AppBar は透明で背景が上まで通っている
    if (_isPlaylist) {
      final plState = ref.watch(playlistPlayerProvider);
      final nextIdx = plState.peekNextTrackIndex();
      final listOpen = _showTrackList;
      // extendBodyBehindAppBar なので padding.top が AppBar の下端
      final topInset = MediaQuery.paddingOf(context).top;
      return Stack(
        children: [
          Positioned.fill(child: _buildToneBackground()),
          Column(
            children: [
              SizedBox(height: topInset + AppSpacing.sm),
              if (!_hideVideo)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: PlaylistBottomBar.margin),
                  child: ClipRRect(
                    borderRadius: AppRadius.borderXl,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: TransitionStage(
                        currentItem: _currentItem,
                        onFullscreen: _enterFullscreen,
                      ),
                    ),
                  ),
                ),
              const KaraokeSubtitle(),
              const SizedBox(height: AppSpacing.lg + 2),
              NowPlayingHeader(
                track: plState.currentTrack,
                index: plState.currentTrackIndex,
                count: plState.trackCount,
                next: nextIdx != null ? plState.tracks[nextIdx] : null,
                onNextTap: () => _setTrackListOpen(true),
              ),
              const SizedBox(height: AppSpacing.lg + 2),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  // 一覧は縦に伸ばして置きたいので、既定の中央寄せ Stack ではなく expand
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  child: listOpen
                      ? _buildTrackListPanel()
                      : const SizedBox.expand(key: ValueKey('noList')),
                ),
              ),
              PlaylistBottomBar(
                seekbar: PlaylistSeekArea(
                  compact: _compactSeekbar,
                  waveHeight: listOpen ? 44 : 96,
                  mixHeight: listOpen ? 64 : 120,
                  onToggleCompact: () =>
                      setState(() => _compactSeekbar = !_compactSeekbar),
                  onRetryWaveform: _retryWaveform,
                  waveformFor: (item) => _waveformCache[item.id],
                  titleFor: (item) => item.title,
                ),
                compact: listOpen,
                shuffle: plState.shuffle,
                onShuffle: _isPreloading ? null : _toggleShuffle,
                repeatMode: plState.repeatMode,
                onRepeat: _cycleRepeatMode,
                onPrev: plState.hasPrev && !_trackLoading ? _manualPrev : null,
                onNext: plState.hasNext && !_trackLoading ? _manualNext : null,
                onMore: _showMoreSheet,
                onToggleList: () => _setTrackListOpen(!listOpen),
                firstVerse: plState.firstVerseMode,
                onToggleFirstVerse: _toggleFirstVerseMode,
              ),
            ],
          ),
        ],
      );
    }

    // 単体再生: スクロール可能レイアウト
    return SingleChildScrollView(
      child: Column(
        children: [
          Stack(
            children: [
              VideoPlayerWidget(onFullscreen: _enterFullscreen),
              const Positioned.fill(child: LyricsOverlay()),
            ],
          ),
          const KaraokeSubtitle(),
          const PlayerControls(),
          LoopSeekbar(
            compact: _compactSeekbar,
            onToggleCompact: () =>
                setState(() => _compactSeekbar = !_compactSeekbar),
            allowMarkerDrag: _editMode,
            onRetryWaveform: _retryWaveform,
          ),
          _buildRegionAndLoopPanel(regions, loop),
          SizedBox(height: AppSpacing.xxl + bottomInset),
        ],
      ),
    );
  }

  /// サムネの色味を薄く敷いた背景。曲が変わるとなめらかに移る
  Widget _buildToneBackground() {
    final path = _currentItem.thumbnailPath;
    final tone =
        path == null ? null : ref.watch(thumbToneProvider(path)).valueOrNull;
    final theme = Theme.of(context);
    final colors = (tone ?? ThumbTone.fallback).gradient(
      theme.scaffoldBackgroundColor,
      dark: theme.brightness == Brightness.dark,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    );
  }

  /// トラック一覧の開閉。開いたら再生中の曲が上の方に来るように送る
  void _setTrackListOpen(bool open) {
    if (open == _showTrackList) return;
    setState(() => _showTrackList = open);
    if (!open) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_trackListController.hasClients) return;
      final idx = ref.read(playlistPlayerProvider).currentTrackIndex ?? 0;
      final target = ((idx - 1) * _trackRowHeight)
          .clamp(0.0, _trackListController.position.maxScrollExtent);
      _trackListController.jumpTo(target);
    });
  }

  /// 開閉できるトラック一覧（ガラス板）。見出しに曲数、「…」でその他、▾ で閉じる
  Widget _buildTrackListPanel() {
    final plState = ref.watch(playlistPlayerProvider);
    final textTheme = Theme.of(context).textTheme;
    return GlassPanel(
      key: const ValueKey('trackList'),
      margin: const EdgeInsets.fromLTRB(PlaylistBottomBar.margin, 0,
          PlaylistBottomBar.margin, AppSpacing.lg),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.sm, 0),
            child: Row(
              children: [
                Text('トラック一覧', style: textTheme.titleSmall),
                const SizedBox(width: AppSpacing.md),
                Text('${plState.trackCount} 曲', style: textTheme.labelSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: AppIconSizes.md),
                  onPressed: _showMoreSheet,
                  tooltip: 'その他',
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => _setTrackListOpen(false),
                  tooltip: '一覧を閉じる',
                ),
              ],
            ),
          ),
          Expanded(child: _buildPlaylistPanel(0)),
        ],
      ),
    );
  }

  void _showMoreSheet() {
    final plState = ref.read(playlistPlayerProvider);
    PlayerMoreSheet.show(
      context,
      PlayerMoreSheet(
        firstVerseMode: plState.firstVerseMode,
        onToggleFirstVerse: _toggleFirstVerseMode,
        onToggleVolumeNorm: _toggleVolumeNorm,
        onEditAb: _showAbEditDialog,
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
    ref.read(volumeNormProvider.notifier).state = !current;
    if (!current) {
      // ONにした時点で現在の波形で正規化を適用
      final waveform = ref.read(waveformDataProvider);
      if (waveform != null) _applyVolumeNormalization(waveform);
    } else {
      // OFFにしたらデフォルト音量に戻す
      _baseVolume = 100.0;
      try { ref.read(playerProvider).setVolume(100); } catch (_) {}
    }
  }

  // --- Region + Loop panel (editor-style 2-panel layout) ---

  Widget _buildRegionAndLoopPanel(
      List<LoopRegion> regions, LoopState loop) {
    final notifier = ref.read(loopProvider.notifier);
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final hasSource = ref.watch(videoSourceProvider) != null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
        child: SizedBox(
          height: 200,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // === Left: Region list ===
              SizedBox(
                width: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 「全体」（固定）
                    RegionTile(
                      name: '全体',
                      isActive: _activeRegionIdx == -1,
                      pointAMs: null,
                      pointBMs: null,
                      onTap: _clearRegion,
                    ),
                    Divider(height: 1,
                        color: theme.dividerColor.withValues(alpha: 0.3)),
                    // 区間リスト（スクロール可能）
                    if (regions.isNotEmpty)
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            for (var i = 0; i < regions.length; i++) ...[
                              RegionTile(
                                name: regions[i].name,
                                isActive: i == _activeRegionIdx,
                                pointAMs: regions[i].pointAMs,
                                pointBMs: regions[i].pointBMs,
                                onTap: () => _selectRegion(i),
                                onLongPress: () => _showRegionMenu(i),
                              ),
                              if (i < regions.length - 1)
                                Divider(height: 1,
                                    color: theme.dividerColor.withValues(alpha: 0.3)),
                            ],
                          ],
                        ),
                      )
                    else
                      const Spacer(),
                    // 追加ボタン（固定）
                    const SizedBox(height: AppSpacing.xs),
                    SizedBox(
                      width: double.infinity,
                      height: 28,
                      child: OutlinedButton.icon(
                        onPressed: regions.length < _maxRegions ? _addRegion : null,
                        icon: const Icon(Icons.add, size: AppIconSizes.xs),
                        label: Text(
                          regions.length < _maxRegions ? '追加' : '上限',
                          style: textTheme.labelSmall,
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          side: BorderSide(color: Colors.grey.shade700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              VerticalDivider(
                width: AppSpacing.xl,
                thickness: 1,
                color: theme.dividerColor.withValues(alpha: 0.3),
              ),

              // === Right: Loop controls ===
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Loop toggle + duration
                    Row(
                      children: [
                        SizedBox(
                          height: 28,
                          child: FilledButton.icon(
                            onPressed: hasSource
                                ? () => notifier.toggleEnabled()
                                : null,
                            icon: Icon(
                              loop.enabled
                                  ? Icons.repeat_on
                                  : Icons.repeat,
                              size: AppIconSizes.s,
                            ),
                            label: Text(
                              loop.enabled ? 'Loop ON' : 'Loop OFF',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: loop.enabled
                                  ? theme.colorScheme.primary
                                  : theme
                                      .colorScheme.surfaceContainerHighest,
                              foregroundColor: loop.enabled
                                  ? Colors.black
                                  : Colors.grey,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10),
                              minimumSize: Size.zero,
                            ),
                          ),
                        ),
                        const Spacer(),
                        // 編集/保存ボタン（区間選択時のみ）
                        if (_activeRegionIdx >= 0)
                          SizedBox(
                            height: 26,
                            child: TextButton.icon(
                              onPressed: _editMode
                                  ? _finishEdit
                                  : () => setState(() => _editMode = true),
                              icon: Icon(
                                _editMode ? Icons.check : Icons.edit,
                                size: AppIconSizes.xs,
                                color: _editMode
                                    ? AppTheme.accentGreen
                                    : Colors.grey,
                              ),
                              label: Text(
                                _editMode ? '保存' : '編集',
                                style: textTheme.labelSmall!.copyWith(
                                  color: _editMode
                                      ? AppTheme.accentGreen
                                      : Colors.grey,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),

                    // --- Edit mode: full A/B controls ---
                    if (_editMode)
                      AbEditControls(
                        loop: loop,
                        notifier: notifier,
                        step: _editStep,
                        onStepChanged: (s) => setState(() => _editStep = s),
                        onSeek: _seekTo,
                        onSetA: hasSource
                            ? () => notifier.setPointA(
                                ref.read(playerProvider).state.position)
                            : null,
                        onSetB: hasSource
                            ? () => notifier.setPointB(
                                ref.read(playerProvider).state.position)
                            : null,
                      )
                    else if (_activeRegionIdx == -1) ...[
                      // --- 全体 ---
                      const Spacer(),
                      // Gap（LoopON時）
                      if (loop.enabled)
                        LoopGapSlider(
                            gapSeconds: loop.gapSeconds,
                            onChanged: notifier.setGap),
                      if (hasSource)
                        SizedBox(
                          width: double.infinity,
                          height: 28,
                          child: OutlinedButton.icon(
                            onPressed: () => _showExportDialog(
                                fullTrack: !loop.hasBothPoints),
                            icon: const Icon(
                                Icons.file_download_outlined,
                                size: AppIconSizes.xs),
                            label: Text(
                                loop.hasBothPoints
                                    ? '区間を書き出し'
                                    : '全体を書き出し',
                                style: textTheme.labelSmall),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                  color: Colors.grey.shade700),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.md),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      AppRadius.borderSm),
                            ),
                          ),
                        ),
                    ] else ...[
                      // --- Non-edit: read-only A/B display ---
                      LoopPointDisplay(
                          label: 'A',
                          color: AppTheme.pointAColor,
                          time: loop.pointA,
                          onSeek: _seekTo),
                      const SizedBox(height: AppSpacing.sm),
                      LoopPointDisplay(
                          label: 'B',
                          color: AppTheme.pointBColor,
                          time: loop.pointB,
                          onSeek: _seekTo),
                      const Spacer(),
                      // Gap（LoopON時）
                      if (loop.enabled)
                        LoopGapSlider(
                            gapSeconds: loop.gapSeconds,
                            onChanged: notifier.setGap),
                      SizedBox(
                        width: double.infinity,
                        height: 28,
                        child: OutlinedButton.icon(
                          onPressed: loop.hasBothPoints
                              ? () => _showExportDialog(fullTrack: false)
                              : null,
                            icon: const Icon(Icons.file_download_outlined,
                                size: AppIconSizes.xs),
                            label: Text('書き出し',
                                style: textTheme.labelSmall),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                  color: Colors.grey.shade700),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.md),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      AppRadius.borderSm),
                            ),
                          ),
                        ),
                    ],

                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _seekTo(Duration time) => ref.read(playerProvider).seek(time);

  /// プレイリストモード: AB区間の微調整 + 区間登録ダイアログ
  void _showAbEditDialog() {
    final loopNotifier = ref.read(loopProvider.notifier);
    final totalMs = ref.read(playerProvider).state.duration.inMilliseconds;
    var aMs = ref.read(loopProvider).pointA?.inMilliseconds ?? 0;
    var bMs = ref.read(loopProvider).pointB?.inMilliseconds ??
        (totalMs > 0 ? totalMs : 0);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final textTheme = Theme.of(ctx).textTheme;

          Widget timeRow(String label, int ms, Color color, ValueChanged<int> onChanged) {
            return Row(
              children: [
                Text(label, style: textTheme.titleSmall!.copyWith(color: color)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: () => onChanged(ms - 1000),
                ),
                Text(
                  TimeUtils.formatShort(Duration(milliseconds: ms)),
                  style: textTheme.bodyLarge!.copyWith(
                      color: color, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => onChanged(ms + 1000),
                ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('AB区間を編集'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                timeRow('A', aMs, AppTheme.pointAColor, (v) {
                  if (v >= 0 && v < bMs) {
                    loopNotifier.setPointA(Duration(milliseconds: v));
                    setDialogState(() => aMs = v);
                  }
                }),
                const SizedBox(height: AppSpacing.md),
                timeRow('B', bMs, AppTheme.pointBColor, (v) {
                  if (v > aMs && (totalMs <= 0 || v <= totalMs)) {
                    loopNotifier.setPointB(Duration(milliseconds: v));
                    setDialogState(() => bMs = v);
                  }
                }),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('閉じる'),
              ),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _saveCurrentAbAsRegion(aMs, bMs);
                },
                icon: const Icon(Icons.save_alt, size: AppIconSizes.sm),
                label: const Text('区間として登録'),
              ),
            ],
          );
        },
      ),
    );
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
    item.regions.add(region);
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

  Widget _buildPlaylistControls() {
    final textTheme = Theme.of(context).textTheme;
    final plState = ref.watch(playlistPlayerProvider);
    final currentIdx = plState.currentTrackIndex;

    // Repeat mode icon
    IconData repeatIcon;
    Color? repeatColor;
    switch (plState.repeatMode) {
      case pl.RepeatMode.none:
        repeatIcon = Icons.repeat;
        repeatColor = Colors.grey;
      case pl.RepeatMode.all:
        repeatIcon = Icons.repeat;
        repeatColor = AppTheme.accentGreen;
      case pl.RepeatMode.single:
        repeatIcon = Icons.repeat_one;
        repeatColor = AppTheme.accentGreen;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        child: Column(
          children: [
            // Controls row: shuffle, repeat, prev, track info, next, 1番, 調整
            Row(
              children: [
                // Shuffle
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    size: AppIconSizes.ml,
                    color: plState.shuffle
                        ? AppTheme.accentGreen
                        : Colors.grey,
                  ),
                  onPressed: _isPreloading ? null : _toggleShuffle,
                  tooltip: 'シャッフル',
                  visualDensity: VisualDensity.compact,
                ),
                // Repeat mode
                IconButton(
                  icon: Icon(repeatIcon, size: AppIconSizes.ml, color: repeatColor),
                  onPressed: _cycleRepeatMode,
                  tooltip: switch (plState.repeatMode) {
                    pl.RepeatMode.none => 'リピートなし',
                    pl.RepeatMode.all => '全曲リピート',
                    pl.RepeatMode.single => '1曲リピート',
                  },
                  visualDensity: VisualDensity.compact,
                ),
                // Prev
                IconButton(
                  icon: const Icon(Icons.skip_previous, size: AppIconSizes.xl),
                  onPressed: plState.hasPrev && !_trackLoading ? _manualPrev : null,
                  visualDensity: VisualDensity.compact,
                ),
                // Track info
                Expanded(
                  child: Text(
                    currentIdx != null
                        ? '${currentIdx + 1} / ${plState.trackCount}'
                        : '- / ${plState.trackCount}',
                    style: textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
                // Next
                IconButton(
                  icon: const Icon(Icons.skip_next, size: AppIconSizes.xl),
                  onPressed: plState.hasNext && !_trackLoading ? _manualNext : null,
                  visualDensity: VisualDensity.compact,
                ),
                // 1番だけモード
                IconButton(
                  icon: Icon(
                    Icons.looks_one_outlined,
                    size: AppIconSizes.ml,
                    color: plState.firstVerseMode
                        ? AppTheme.accentGreen
                        : Colors.grey,
                  ),
                  onPressed: _toggleFirstVerseMode,
                  tooltip: '1番だけ',
                  visualDensity: VisualDensity.compact,
                ),
                // AB編集（常時表示）
                IconButton(
                  icon: Icon(
                    Icons.tune,
                    size: AppIconSizes.ml,
                    color: ref.watch(loopProvider).hasBothPoints
                        ? AppTheme.accentGreen
                        : Colors.grey,
                  ),
                  onPressed: _showAbEditDialog,
                  tooltip: 'AB区間を編集',
                  visualDensity: VisualDensity.compact,
                ),
                // 音量正規化
                IconButton(
                  icon: Icon(
                    Icons.equalizer,
                    size: AppIconSizes.ml,
                    color: ref.watch(volumeNormProvider)
                        ? AppTheme.accentGreen
                        : Colors.grey,
                  ),
                  onPressed: _toggleVolumeNorm,
                  tooltip: '音量正規化',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
