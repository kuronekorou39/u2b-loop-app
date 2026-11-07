import 'dart:async';
import 'dart:io';

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
import '../models/playlist_track.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_engine.dart';
import '../providers/playlist_player_provider.dart';
import '../services/save_flow.dart';
import '../services/playback/load_progress.dart';
import '../services/playback/mini_player_transport.dart';
import '../services/playback/pip_bridge.dart';
import '../services/playback/playlist_transport.dart';
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
import '../widgets/player/first_verse_sheet.dart';

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

  /// 単体再生で最初に選ぶ区間（null なら 1 つ目）
  final int? initialRegionIndex;

  /// 単体再生を AB 編集の状態で開く（詳細の「AB 設定」。区間が無ければ 1 つ作る）。
  /// v1.126.0 で AB 設定専用の画面をこれに統合した
  final bool startEditing;

  const PlayerScreen({
    super.key,
    required this.item,
    this.playlistItems,
    this.initialIndex = 0,
    this.regionSelections,
    this.disabledItemIds,
    this.playlistName,
    this.playlistId,
    this.initialRegionIndex,
    this.startEditing = false,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver
    implements TransportHost {

  bool _loading = true;
  String? _loadError;

  /// 読み込みの進捗・曲を開く手順・波形は共通の部品。
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

  /// AB 編集中。微調整の刻みは loopProvider の adjustStep
  bool _editMode = false;

  StreamSubscription<String>? _bandsSub;

  /// 帯域の波形が保存された: プレイリストの鳴っている曲か次の曲なら、ミックス点を探し直す
  void _onBandsSaved(String itemId) {
    if (!mounted || !_isPlaylist) return;
    final ps = ref.read(playlistPlayerProvider);
    final current = ps.currentTrack;
    final preloaded = _transport.preloadedIndex;
    final next = preloaded == null || preloaded >= ps.tracks.length
        ? null
        : ps.tracks[preloaded];
    for (final (track, preload) in [(current, false), (next, true)]) {
      if (track == null || track.item.id != itemId) continue;
      final waveform = _waveformCache[itemId] ??
          (preload ? null : ref.read(waveformDataProvider));
      if (waveform == null || waveform.isEmpty) continue;
      unawaited(_updateMixPoints(track, waveform, preload: preload));
    }
  }

  /// プレイリストの進行（先読み・自動遷移・手動の前後と選曲・1 番だけモードのフェード）
  late final _transport = PlaylistTransportController(
    deck: EngineTransportDeck(ref.read),
    host: this,
    isPlaylist: _isPlaylist,
  );

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
  /// 画面と同じ PlaylistTransportController を、画面の無い受け口で動かす
  PlaylistTransportController? _miniTransport;

  /// 字幕の用意（オフライン SRT / YouTube 取得 / 言語の選び直し）
  late final _subtitles = SubtitleLoader(ref, isMounted: () => mounted);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playerScreenActive = true;
    // 帯域の波形はデコードの少しあとで保存される。鳴っている曲・次の曲のができたら、
    // 低音でミックス点を探し直す
    _bandsSub = WaveformCache.bandsChanged.listen(_onBandsSaved);

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
            if (_isPlaylist) _transport.manualNext();
          case PipAction.prev:
            if (_isPlaylist) _transport.manualPrev();
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
        final engine = ref.read(playlistEngineProvider);
        engine.endSession(keepCrossfade: true);
        ref.read(loopProvider.notifier).setCurrentItem(_currentItem.id);
        _transport.setupCallbacks();
        PipBridge.setAutoPiP(
            enabled: true, isPlaylist: _isPlaylist, item: _currentItem);
        _updatePiPPlayState();
        // 進行役が先読みして予約した次曲（✓）があれば、そのまま引き継ぐ。
        // 捨てて読み直すと ✓ が消え、重ね表示も予約し直すまで前の組（1 手古い帯）になる
        final ps = ref.read(playlistPlayerProvider);
        final nextIdx = ps.peekNextTrackIndex();
        final armed = engine.armedTrack;
        final keep = _isPlaylist &&
            armed != null &&
            nextIdx != null &&
            ps.tracks[nextIdx].item.id == armed.item.id;
        if (keep) _transport.adoptPreloaded(nextIdx);
        _transport.startPreloadMonitor(keepPreload: keep);
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
        stopAllPlayers(ref);
      }

      // 前のプレイリスト（ミニプレイヤーで続いていた分も）を打ち切る
      final engine = ref.read(playlistEngineProvider);
      _isPlaylist ? engine.endSession() : engine.endPlaylist();
      resetPlayerSlots(ref);
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
    _bandsSub?.cancel();
    playerScreenActive = false;
    _progress.dispose();
    _overlayHideTimer?.cancel();
    _trackListController.dispose();
    _transport.dispose();
    // 全画面モード解除（バックジェスチャ等で全画面のまま離脱しても向きを戻す）
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    // ミニプレイヤー有効時は再生状態を温存
    final miniActive = ref.read(miniPlayerProvider).active;

    // 自動PiP: ミニプレイヤー有効時は維持（PiP突入後にPlayerScreenに遷移する）
    if (!miniActive) {
      PipBridge.setAutoPiP(enabled: false);
      try {
        ref.read(loopProvider.notifier).setCurrentItem(null);
        stopAllPlayers(ref);
        ref.read(loopProvider.notifier).onBPointReached = null;
        ref.read(loopProvider.notifier).onTrackEnd = null;
        if (_isPlaylist) ref.read(playlistPlayerProvider.notifier).clear();
        ref.read(playlistEngineProvider).endSession();
        resetPlayerSlots(ref);
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
              await engine.activePlayer.playOrPause();
              notify();
            case PipAction.next:
              await transport?.manualNext();
            case PipAction.prev:
              await transport?.manualPrev();
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
  // プレイリスト再生制御は PlaylistTransportController（services/playback/playlist_transport.dart）。
  // ここには画面にしか無いもの（映像・波形・字幕・区間）の受け口だけを置く
  // =====================================================================

  @override
  bool get initialLoading => _loading;

  @override
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  bool reloadCurrent() {
    _loadItem();
    return true;
  }

  @override
  void loadTrackRegion(PlaylistTrack track) => _loadTrackRegion(track);

  @override
  void showSource(PlaylistTrack track, {String? openedUri}) {
    final item = track.item;
    ref.read(videoSourceProvider.notifier).state = VideoSource(
      type: item.isYouTube ? VideoSourceType.youtube : VideoSourceType.local,
      uri: openedUri ?? item.uri,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );
  }

  /// 手元の波形（一覧からは消さない。前曲に戻ったとき、重ね表示で次曲の波形として使う）。
  /// 無ければ作る
  @override
  void showWaveform(PlaylistTrack track) {
    final item = track.item;
    final cachedWaveform = _waveformCache[item.id];
    ref.read(waveformErrorProvider.notifier).state = null;
    if (cachedWaveform != null) {
      ref.read(waveformDataProvider.notifier).state = cachedWaveform;
      ref.read(waveformLoadingProvider.notifier).state = false;
      return;
    }
    ref.read(waveformDataProvider.notifier).state = null;
    final source = ref.read(videoSourceProvider);
    if (source != null) _generateWaveform(source, item);
  }

  @override
  void endLoading() {
    if (mounted) setState(() => _loading = false);
  }

  /// 字幕（プレイリスト曲切替時）: キャッシュSRT優先、無ければネット取得
  @override
  void onTrackSwitched(PlaylistTrack track) => _subtitles.loadFor(track.item);

  @override
  void onPreloaded(PlaylistTrack track, Object? manifest,
      {required bool Function() stillCurrent}) {
    if (_waveformCache.containsKey(track.item.id)) return;
    _preloadWaveform(track, manifest as StreamManifest?, stillCurrent);
  }

  @override
  double normalizedVolume(LoopItem item) => _normalizedVolume(item);

  /// 重ね表示の次曲の波形。手元に無ければ保存済みの波形を読みに行く（1 曲につき 1 回）
  final _mixWaveformLoads = <String>{};
  List<double>? _mixWaveformFor(LoopItem item) {
    // 長い動画は波形を出さない（以前作った波形が残っていても位置がずれている）
    if (WaveformService.tooLongForWaveform(durationMs: item.durationMs)) return null;
    final cached = _waveformCache[item.id];
    if (cached != null) return cached;
    if (_mixWaveformLoads.add(item.id)) {
      WaveformCache.load(item.id).then((w) {
        if (w == null || w.isEmpty || !mounted) return;
        _waveformCache[item.id] = w;
        setState(() {});
      });
    }
    return null;
  }

  void _loadTrackRegion(PlaylistTrack track) {
    // 曲が変わったら前の曲の AB 編集は閉じる（1 番を直していたら覚える）
    if (_editMode) _rememberFirstVerse();
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
    _transport.setupCallbacks();
    if (mounted) setState(() {});
  }

  /// 1番だけモード: この曲の 1 番の範囲を A/B にセット。
  /// 手で直した範囲（LoopItem.firstVerseAMs/BMs）があればそれを、無ければ波形から切断点を探す。
  /// AB設定済みの区間トラックには適用しない（_loadTrackRegionで分岐済み）
  void _applyFirstVerseCut(PlaylistTrack track, [int retryCount = 0]) {
    // フェードアウト監視のみキャンセル（フェードインは中断しない）
    _transport.cancelFadeOut();
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

    // 手で直した範囲（画面が持つ track.item は古いことがあるので保存済みの方を見る）
    final saved =
        ref.read(loopItemsProvider.notifier).byId(track.item.id) ?? track.item;
    if (saved.hasFirstVerse) {
      final a = Duration(milliseconds: saved.firstVerseAMs!);
      final notifier = ref.read(loopProvider.notifier);
      notifier.setPointA(a);
      notifier.setPointB(Duration(milliseconds: saved.firstVerseBMs!));
      if (!ref.read(loopProvider).enabled) notifier.toggleEnabled();
      // A が曲の頭でなければ A から聴かせる。交差で入ってきた曲は位置をエンジンが決めるので触らない
      final player = ref.read(playerProvider);
      if (a > Duration.zero &&
          player.state.position < a &&
          !ref.read(playlistEngineProvider).isCrossfading) {
        player.seek(a);
      }
      _transport.startFadeOutMonitor(saved.firstVerseBMs!);
      return;
    }

    // キャッシュ or プロバイダから波形を取得
    final waveform = _waveformCache[track.item.id] ??
        ref.read(waveformDataProvider);
    final range = ref.read(verseSearchRangeProvider);
    final cutMs = VerseDetector.findCutPoint(
      waveform: waveform,
      durationMs: durationMs,
      searchStartMs: range.startSec * 1000,
      searchEndMs: range.endSec * 1000,
    );

    if (cutMs != null) {
      final notifier = ref.read(loopProvider.notifier);
      notifier.setPointA(Duration.zero);
      notifier.setPointB(Duration(milliseconds: cutMs));
      if (!ref.read(loopProvider).enabled) notifier.toggleEnabled();
      _transport.startFadeOutMonitor(cutMs);
    }
  }

  /// 波形からミックス点（ドロップ / アウトロ）を求めて LoopItem に残す。
  /// 一度求めたものは使い回す（将来の手動上書きを壊さないため）。
  /// 次曲（[preload]）なら、決まった開始位置へプリロード側を取り直す
  Future<void> _updateMixPoints(PlaylistTrack track, List<double> waveform,
      {required bool preload}) async {
    final item = track.item;
    // 帯域の波形があれば低音で探す。全体の音量で探した曲は、帯域ができたら探し直す
    final bands = await WaveformCache.loadBands(item.id);
    final needPoints = (item.mixInMs == null && item.mixOutMs == null) ||
        (bands != null && item.mixPointsFromBass != true);
    // 音量の流れ（おまかせ用）と流れそのもの（入り口を選ぶ用）はミックス点より後から
    // 入ったので、点があっても無ければ求める
    final needEnergy = item.headDb == null || item.energyDb == null;
    if (!needPoints && !needEnergy) return;
    final engine = ref.read(playlistEngineProvider);
    final duration = (preload ? engine.preloadPlayer : engine.activePlayer)
        .state
        .duration;
    if (duration <= Duration.zero) return;
    MixPoints points;
    if (needPoints) {
      points = MixPointDetector.fromWaveform(
        waveform,
        duration.inMilliseconds,
        leadingSilenceMs: item.introSkipMs,
        trailingSilenceMs: item.outroSkipMs,
      );
      if (bands != null) {
        points = MixPointDetector.withBass(bands, duration.inMilliseconds,
            fallback: points,
            leadingSilenceMs: item.introSkipMs,
            trailingSilenceMs: item.outroSkipMs);
      }
    } else {
      points = MixPoints(mixInMs: item.mixInMs, mixOutMs: item.mixOutMs);
    }
    final energy = needEnergy
        ? EnergyProfile.fromWaveform(
            waveform,
            duration.inMilliseconds,
            leadingSilenceMs: item.introSkipMs,
            trailingSilenceMs: item.outroSkipMs,
            mixInMs: points.mixInMs,
          )
        : null;
    final curve = needEnergy
        ? EnergyProfile.curve(waveform, duration.inMilliseconds)
        : null;
    if (points == MixPoints.none &&
        (energy == null || energy.isEmpty) &&
        (curve == null || curve.isEmpty)) {
      return;
    }
    await ref
        .read(loopItemsProvider.notifier)
        .saveMixPoints(item.id, points,
            energy: energy,
            energyCurve: curve,
            fromBass: needPoints ? bands != null : null);
    // Hive の box にあるのと同じインスタンスなので item 自体も更新されている
    debugPrint('[MixPoint] ${item.title}: $points ${energy ?? ''}');
    if (preload && needPoints) await engine.realignPreload(track);
  }

  /// 波形を先行生成してキャッシュに保存（fire-and-forget）
  Future<void> _preloadWaveform(PlaylistTrack track, StreamManifest? manifest,
      bool Function() stillCurrent) async {
    try {
      final item = track.item;
      final service = WaveformService();
      // プリロード側のプレイヤーは準備済みなので長さが分かる（0 なら不明として扱われる）
      final preloadDuration = ref.read(preloadPlayerProvider).state.duration;
      // 長い動画は波形を作らない
      if (WaveformService.tooLongForWaveform(
          durationMs: item.durationMs, playerDuration: preloadDuration)) {
        return;
      }
      // 解析と、帯域の波形（色の濃淡）がまだ無ければその分も PCM を受け取る
      final onPcm = await WaveformCache.pcmSinkWithBands(
          item.id,
          AudioAnalysisService.sinkFor(ref.read(loopItemsProvider.notifier), item,
              duration: preloadDuration == Duration.zero ? null : preloadDuration));
      List<double>? waveform;

      // 保存済みの波形は先に使う（重ね表示・切り替わった後の表示がデコードを待たない）。
      // 解析・帯域が要らない、またはこの起動中にもう試した曲は音声 DL ごと省く
      final saved = await WaveformCache.load(item.id);
      if (saved != null && saved.isNotEmpty) {
        // 波形は曲のものなので、世代が変わっても残す（重ね表示が使う）
        _waveformCache[item.id] = saved;
        if (stillCurrent()) {
          await _updateMixPoints(track, saved, preload: true);
        }
        if (onPcm == null || WaveformService.decodeTried(item.id)) return;
      }
      WaveformService.markDecodeTried(item.id);

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
          if (!stillCurrent()) {
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
        _waveformCache[item.id] = waveform;
        if (stillCurrent()) {
          await _updateMixPoints(track, waveform, preload: true);
        }
      }
    } catch (_) {
      // 波形プリロード失敗は無視（再生時に再試行される）
    }
  }

  // --- Loading ---

  /// 曲を開く（手順は PlayerLoader）。
  /// オフライン保存があればそれを優先し、YouTube の波形用音声は裏で先読みする
  Future<void> _loadItem() async {
    _transport.cancelFade();
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
    // 開き直すので前の曲との重ね表示も成り立たない（残していた前の曲も止める）
    ref.read(playlistEngineProvider).releaseParked();

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
          _transport.loadErrors++;
          if (_transport.loadErrors <
              PlaylistTransportController.maxLoadErrors) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && _loadError != null) _transport.autoAdvance();
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
    _transport.setupCallbacks();

    _loader.finish();
    setState(() => _loading = false);

    // 再生カウント: 現在のアイテムを設定
    ref.read(loopProvider.notifier).setCurrentItem(item.id);

    // 音量正規化（前に測ってあればこの時点で合う。無ければ波形ができたとき）
    _applyVolumeNorm(item);

    // Auto-play + バックグラウンド再生サービス開始
    player.play();
    WakelockPlus.enable();
    PipBridge.startPlaybackService(item);

    // フェードイン（自動遷移の開き直しから来た場合）と先読みの開始
    _transport.onItemLoaded();

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
      final i = (widget.initialRegionIndex ?? 0).clamp(0, regions.length - 1);
      setState(() => _activeRegionIdx = i);
      _loadRegion(regions[i]);
      if (widget.startEditing) {
        final a = regions[i].pointAMs;
        if (a != null) ref.read(playerProvider).seek(Duration(milliseconds: a));
        _beginSingleEdit();
      }
    } else if (widget.startEditing) {
      _addRegion();
    }
  }

  /// 単体再生の AB 編集を始めたとき（区間を選び直したとき）の A/B。「元に戻す」で戻す先
  (Duration?, Duration?)? _singleEditStart;

  /// 単体再生の AB 編集に入る（今の A/B を「元に戻す」の戻り先として覚える）
  void _beginSingleEdit() {
    final loop = ref.read(loopProvider);
    _singleEditStart = (loop.pointA, loop.pointB);
    setState(() => _editMode = true);
  }

  /// 編集を始めたときの A/B に戻す（保存はしない。「保存して終了」で残る）
  void _revertSingleEdit() {
    final start = _singleEditStart;
    if (start == null) return;
    final notifier = ref.read(loopProvider.notifier);
    notifier.setPointA(start.$1);
    notifier.setPointB(start.$2);
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
    if (_editMode) _beginSingleEdit();
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

  /// 区間一覧の編集ルール（RegionEditController）。状態は item の regions 本体と
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

    setState(() => _activeRegionIdx = editor.selected);
    _loadRegion(region);
    _beginSingleEdit();
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
          icon: Icons.clear,
          label: 'A・B をクリア',
          onTap: () => _clearRegionPoints(index),
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

  /// 区間の A・B を未設定に戻す（区間そのものは残す）
  Future<void> _clearRegionPoints(int index) async {
    final regions = _currentItem.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    final ok = await AppDialogs.confirm(context,
        title: 'A・B をクリア',
        message: '「${regions[index].name}」の A・B を未設定に戻しますか？',
        confirmLabel: 'クリア',
        destructive: true);
    if (!ok || !mounted) return;
    if (index == _activeRegionIdx) {
      ref.read(loopProvider.notifier).reset();
      _syncRegionFromLoop();
    } else {
      final region = _currentItem.ensureRegions()[index];
      region.pointAMs = null;
      region.pointBMs = null;
    }
    setState(() {});
    _saveRegions();
  }

  /// 編集モード終了時にAB値を保存
  void _finishEdit() {
    _syncRegionFromLoop();
    _saveRegions();
    _rememberFirstVerse();
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
        AppToast.instance.show(
          AppSnackBar.info('PiPに入れませんでした'),
        );
      }
    }
  }

  void _updatePiPPlayState() =>
      PipBridge.updatePlayState(ref.read(playerProvider).state.playing);

  // --- Export ---

  /// 保存シート（アプリ内に保存 / 端末に書き出し）。AB があれば区間か曲全体かを選べる。
  /// 単体再生・全画面・プレイリスト再生中（今の曲）で共通
  Future<void> _showExportDialog({bool fullTrack = false}) async {
    final item = _currentItem;
    final loop = ref.read(loopProvider);
    final hasRange = !fullTrack && loop.hasBothPoints;
    String? rangeText;
    if (hasRange) {
      final durationSec =
          (loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() /
              1000;
      rangeText = '${TimeUtils.formatShort(loop.pointA!)}'
          ' - ${TimeUtils.formatShort(loop.pointB!)}'
          ' (${durationSec.toStringAsFixed(1)}s)';
    }
    final choice = await SaveFlow.showSheet(context,
        title: item.title,
        rangeText: rangeText,
        offline: SaveFlow.canSaveOffline(item));
    if (choice == null || !mounted) return;
    final duration = ref.read(playerProvider).state.duration.inMilliseconds;
    final whole = choice.wholeTrack || !hasRange;
    await SaveFlow.run(
      context,
      ref,
      item: item,
      choice: choice,
      startMs: whole ? 0 : loop.pointA!.inMilliseconds,
      endMs: whole
          ? (duration > 0 ? duration : null)
          : loop.pointB!.inMilliseconds,
      playingUri: ref.read(videoSourceProvider)?.uri,
    );
  }

  // --- Waveform ---

  void _retryWaveform() {
    final source = ref.read(videoSourceProvider);
    if (source != null) _generateWaveform(source, _currentItem);
  }

  /// 波形を作って provider に流し（手順は WaveformLoader）、
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
    final user = ref.read(userVolumeProvider);
    if (!ref.read(volumeNormProvider)) return user;
    final latest = ref.read(loopItemsProvider.notifier).byId(item.id) ?? item;
    return Loudness.volumeFor(latest.loudnessDb, base: user);
  }

  /// [_normalizedVolume] を今のプレイヤーに反映する（フェード中は上限だけ更新）
  void _applyVolumeNorm(LoopItem item) =>
      _transport.setBaseVolume(_normalizedVolume(item));



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
            onTap: () => _transport.selectTrack(trackIndex),
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
    _transport.cancelPreload();

    if (widget.playlistId != null) {
      await ref
          .read(playlistsProvider.notifier)
          .removeItem(widget.playlistId!, track.item.id);
    }

    // 再生中トラックを削除した場合: 次のトラックにスキップ
    if (isCurrent) {
      final newTrack = ref.read(playlistPlayerProvider).currentTrack;
      if (newTrack != null) {
        _transport.cancelFade();
        _loadItem();
      }
    }

    if (mounted) {
      AppToast.instance.show(
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
      preloadingIndex: _transport.preloadingIndex,
      preloadedIndex: _transport.preloadedIndex,
      onSelect: _transport.selectTrack,
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
    // 音量のスライダー・ミュート: 今の曲の正規化をかけてプレイヤーへ（フェード中は上限だけ）
    ref.listen(userVolumeProvider, (_, _) => _applyVolumeNorm(_currentItem));

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
          // 単体再生で AB を編集中に戻ったら、「保存して終了」と同じく残す
          if (_editMode && !_isPlaylist) _finishEdit();
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
            _isPlaylist &&
                _transport.loadErrors >= PlaylistTransportController.maxLoadErrors,
        onRetry: () {
          _transport.loadErrors = 0;
          _loadItem();
        },
        onSkip: _isPlaylist
            ? () {
                _transport.loadErrors = 0;
                _transport.autoAdvance();
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
      // 先読み済みの次曲（✓）は進行役に引き継ぐ（読み直さない）。読み込み中の分は
      // 画面と一緒に止まるので、進行役が自分で読みに行く
      _miniTransport = startMiniTransport(
        ProviderScope.containerOf(context, listen: false).read,
        preloadedIndex: _transport.preloadedIndex,
      );
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
            onShuffle: _transport.isPreloading ? null : _toggleShuffle,
            onRepeat: _cycleRepeatMode,
            onPrev: plState.hasPrev && !_transport.trackLoading
                ? _transport.manualPrev
                : null,
            onNext: plState.hasNext && !_transport.trackLoading
                ? _transport.manualNext
                : null,
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
        _beginSingleEdit();
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
    final plState = _isPlaylist ? ref.watch(playlistPlayerProvider) : null;
    final idx = plState?.currentTrackIndex;
    final subParts = <String>[
      ..._currentItem.musicInfoParts,
      if (plState != null)
        idx != null ? '${idx + 1} / ${plState.trackCount}' : '- / ${plState.trackCount}',
    ];
    return FullscreenPlayerView(
      title: _isPlaylist
          ? (plState?.currentTrack?.displayName ?? _currentItem.title)
          : _currentItem.title,
      subtitle: subParts.join('  ·  '),
      isPlaylist: _isPlaylist,
      onPrev: plState != null && plState.hasPrev && !_transport.trackLoading
          ? _transport.manualPrev
          : null,
      onNext: plState != null && plState.hasNext && !_transport.trackLoading
          ? _transport.manualNext
          : null,
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

  /// 波形・重ね表示の高さ。縦は 120（プレイリスト）。横は脇の高さが足りないので、
  /// 画面の高さに合わせて低くする（コントローラーがスクロールしないように）
  double _seekHeight(bool wide) {
    if (!wide) return 120;
    // 横はコントローラーが動画の下に入るので、動画の場所を残すよう低めに
    final h = MediaQuery.sizeOf(context).height;
    if (h < 380) return 40;
    if (h < 440) return 52;
    if (h < 560) return 72;
    return 96;
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
            waveHeight: _seekHeight(wide),
            mixHeight: _seekHeight(wide),
            onToggleCompact: () =>
                setState(() => _compactSeekbar = !_compactSeekbar),
            onRetryWaveform: _retryWaveform,
            onReplayPrevious: _transport.replayPreviousFrom,
            waveformFor: _mixWaveformFor,
            titleFor: (item) => item.title,
          ),
          listOpen: panelOpen,
          shuffle: plState.shuffle,
          onShuffle: _transport.isPreloading ? null : _toggleShuffle,
          repeatMode: plState.repeatMode,
          onRepeat: _cycleRepeatMode,
          onPrev: plState.hasPrev && !_transport.trackLoading
              ? _transport.manualPrev
              : null,
          onNext: plState.hasNext && !_transport.trackLoading
              ? _transport.manualNext
              : null,
          onMore: _showMoreSheet,
          onToggleList: () => _setPanelOpen(!panelOpen),
          firstVerse: plState.firstVerseMode,
          onToggleFirstVerse: _toggleFirstVerseMode,
          onEditFirstVerse: _editFirstVerse,
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
          barHeight: wide ? _seekHeight(true) : 72,
          // 保存された最新の曲（開いたあとに裏で解析が終わっても線が出るように）
          beatItem: ref.watch(loopItemsProvider
                  .select((l) => l.where((i) => i.id == item.id).firstOrNull)) ??
              item,
        ),
        regionsOpen: panelOpen,
        loop: loop,
        onToggleLoop: notifier.toggleEnabled,
        editing: _editMode,
        canEdit: activeRegion != null,
        onToggleRegions: () => _setPanelOpen(!panelOpen),
        onEdit: _beginSingleEdit,
        onFinishEdit: _finishEdit,
        // 編集を始めたときから A/B を動かしていれば「元に戻す」
        onRevert: _singleEditStart != null &&
                (_singleEditStart!.$1 != loop.pointA ||
                    _singleEditStart!.$2 != loop.pointB)
            ? _revertSingleEdit
            : null,
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
        onResetFirstVerse: () {
          final id = plState.currentTrack?.item.id;
          final saved =
              id == null ? null : ref.read(loopItemsProvider.notifier).byId(id);
          return saved != null && saved.hasFirstVerse ? _resetFirstVerse : null;
        }(),
        onToggleVolumeNorm: _toggleVolumeNorm,
        // AB 編集の UI は全画面には無い（横レイアウトの板）ので、全画面なら解除してから
        onEditAb: () {
          _exitFullscreen();
          _startPlaylistAbEdit();
        },
        onDjMix: () => DjMixSheet.show(context),
        onSave: _showExportDialog,
        hideVideo: _hideVideo,
        onHideVideoChanged: (v) => setState(() => _hideVideo = v),
      ),
    );
  }

  void _toggleShuffle() {
    ref.read(playlistPlayerProvider.notifier).toggleShuffle();
    _transport.onShuffleToggled();
  }

  void _cycleRepeatMode() {
    ref.read(playlistPlayerProvider.notifier).cycleRepeatMode();
    // プリロード済みの次曲が変わった場合のみ捨てる（読み直しは定期チェックで）
    _transport.onRepeatChanged();
  }

  void _toggleFirstVerseMode() {
    ref.read(playlistPlayerProvider.notifier).toggleFirstVerseMode();
    final plState = ref.read(playlistPlayerProvider);
    final track = plState.currentTrack;
    if (track != null && !track.hasRegion) {
      if (plState.firstVerseMode) {
        _applyFirstVerseCut(track);
      } else {
        _transport.cancelFade();
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
    final started = ref.read(loopProvider);
    _editStartPoints = (started.pointA, started.pointB);
    _editTrack = ref.read(playlistPlayerProvider).currentTrack;
    setState(() {
      _editMode = true;
      _panelOpen = false;
    });
  }

  /// AB 編集を始めたときの A/B（閉じたときに直したかどうかを見る）
  (Duration?, Duration?)? _editStartPoints;

  /// AB 編集を始めた曲（閉じる前に次の曲へ進んでも、直した曲に覚えさせる）
  PlaylistTrack? _editTrack;

  /// 1番モード中に AB を直して閉じたら、この曲の 1 番として覚える（次回からそれを使う）。
  /// 区間として登録すると 1 番モードでないふつうの再生まで狭まるので、それとは別に持つ
  void _rememberFirstVerse() {
    final start = _editStartPoints;
    final track = _editTrack;
    _editStartPoints = null;
    _editTrack = null;
    if (!_isPlaylist) return;
    if (!ref.read(playlistPlayerProvider).firstVerseMode ||
        track == null ||
        track.hasRegion) {
      return;
    }
    final loop = ref.read(loopProvider);
    if (!loop.hasBothPoints) return;
    if (start != null && start.$1 == loop.pointA && start.$2 == loop.pointB) return;

    final items = ref.read(loopItemsProvider.notifier);
    final id = track.item.id;
    final before = items.byId(id);
    final prevA = before?.firstVerseAMs, prevB = before?.firstVerseBMs;
    final b = loop.pointB!.inMilliseconds;
    unawaited(items.saveFirstVerse(id,
        aMs: loop.pointA!.inMilliseconds, bMs: b));
    final stillCurrent =
        ref.read(playlistPlayerProvider).currentTrack?.item.id == id;
    if (stillCurrent) _transport.startFadeOutMonitor(b);
    AppToast.instance.show(AppSnackBar.action(
      'この曲の1番として覚えました',
      label: '取り消し',
      onPressed: () async {
        await items.saveFirstVerse(id, aMs: prevA, bMs: prevB);
        if (!mounted) return;
        final current = ref.read(playlistPlayerProvider).currentTrack;
        if (current?.item.id == id) _applyFirstVerseCut(current!);
      },
    ));
  }

  /// 「1番」の長押し: 今の曲の 1 番の終わりを波形の上で直す（自動で探す範囲もここで変えられる）。
  /// 覚えたら 1 番モードも入れる
  Future<void> _editFirstVerse() async {
    final track = ref.read(playlistPlayerProvider).currentTrack;
    if (track == null) return;
    if (track.hasRegion) {
      AppToast.instance.show(
          AppSnackBar.info('区間を選んだ曲は、その区間を流します（1番は使いません）'));
      return;
    }
    final player = ref.read(playerProvider);
    final durationMs = player.state.duration.inMilliseconds;
    if (durationMs <= 0) return;
    final items = ref.read(loopItemsProvider.notifier);
    final saved = items.byId(track.item.id) ?? track.item;
    final rangeBefore = ref.read(verseSearchRangeProvider);
    final result = await FirstVerseSheet.show(
      context,
      title: saved.title,
      waveform: _waveformCache[saved.id] ?? ref.read(waveformDataProvider),
      durationMs: durationMs,
      startMs: saved.firstVerseAMs ?? 0,
      manualEndMs: saved.firstVerseBMs,
      positionMs: player.state.position.inMilliseconds,
    );
    if (!mounted) return;
    final firstVerse = ref.read(playlistPlayerProvider).firstVerseMode;
    switch (result) {
      case FirstVerseSave(:final endMs):
        await items.saveFirstVerse(saved.id,
            aMs: saved.firstVerseAMs ?? 0, bMs: endMs);
        if (!mounted) return;
        if (firstVerse) {
          _applyFirstVerseCut(track);
        } else {
          _toggleFirstVerseMode();
        }
        AppToast.instance
            .show(AppSnackBar.success('この曲の1番として覚えました'));
      case FirstVerseReset():
        await _resetFirstVerse();
      case null:
        // 自動で探す範囲だけ変えたなら、自動の曲は探し直す
        if (firstVerse &&
            !saved.hasFirstVerse &&
            ref.read(verseSearchRangeProvider) != rangeBefore) {
          _applyFirstVerseCut(track);
        }
    }
  }

  /// この曲の 1 番を自動（波形から探す）に戻す
  Future<void> _resetFirstVerse() async {
    final track = ref.read(playlistPlayerProvider).currentTrack;
    if (track == null) return;
    await ref
        .read(loopItemsProvider.notifier)
        .saveFirstVerse(track.item.id);
    if (!mounted) return;
    _applyFirstVerseCut(track);
    AppToast.instance
        .show(AppSnackBar.success('1番を自動に戻しました'));
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
