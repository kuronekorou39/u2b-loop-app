import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/loop_state.dart';
import '../models/playlist_mode.dart' as pl;
import '../models/playlist_track.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_player_provider.dart';
import '../services/waveform_service.dart';
import '../widgets/item_tag_sheet.dart';
import '../widgets/loop/loop_controls.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/video_player_widget.dart';

/// 汎用プレーヤー画面。単体再生・プレイリスト再生・PiP対応。
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

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  static const _pipChannel = MethodChannel('com.u2bloop/pip');

  bool _loading = true;
  String _loadingStatus = '準備中...';
  double _loadingProgress = 0;
  DateTime _lastStepTime = DateTime.now();
  String? _loadError;
  String? _cachedAudioPath;

  int _activeRegionIdx = -1;
  bool _isInPiP = false;
  bool _compactSeekbar = false;
  bool _showPlaylistPanel = false;
  bool _hideVideo = false;
  bool _editMode = false;
  double _editStep = 0.1;
  int? _preloadingTargetIndex;

  // Preload state
  int? _preloadedTrackIndex;
  bool _isPreloading = false;
  Timer? _preloadCheckTimer;
  int _preloadGeneration = 0; // レース条件防止用の世代カウンタ

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

  @override
  void initState() {
    super.initState();
    _compactSeekbar = widget.playlistItems != null;

    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPiPChanged') {
        if (mounted) setState(() => _isInPiP = call.arguments as bool);
      } else if (call.method == 'onPiPAction' &&
          call.arguments == 'playPause') {
        final player = ref.read(playerProvider);
        await player.playOrPause();
        _updatePiPPlayState();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // PiPの再生/一時停止ボタンを同期
      ref.listen(playingProvider, (_, next) {
        final playing = next.valueOrNull ?? false;
        try {
          _pipChannel.invokeMethod('updatePiPPlayState', {'playing': playing});
        } catch (_) {}
      });

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
      }

      _loadItem();
      // 自動PiPを有効化 + 現在の再生状態を送信
      _pipChannel.invokeMethod('setAutoPiP', {'enabled': true});
      _updatePiPPlayState();
    });
  }

  @override
  void deactivate() {
    _preloadCheckTimer?.cancel();
    // 自動PiPを無効化
    try {
      _pipChannel.invokeMethod('setAutoPiP', {'enabled': false});
    } catch (_) {}
    try {
      ref.read(playerAProvider).stop();
      ref.read(playerBProvider).stop();
      ref.read(loopProvider.notifier).onBPointReached = null;
      ref.read(loopProvider.notifier).onTrackEnd = null;
      if (_isPlaylist) ref.read(playlistPlayerProvider.notifier).clear();
      ref.read(activeSlotProvider.notifier).state = ActiveSlot.a;
    } catch (_) {}
    _pipChannel.setMethodCallHandler(null);
    super.deactivate();
  }

  // --- Playlist callbacks ---

  void _setupPlaylistCallbacks() {
    final loopNotifier = ref.read(loopProvider.notifier);

    if (!_isPlaylist) {
      loopNotifier.onBPointReached = null;
      loopNotifier.onTrackEnd = null;
      return;
    }

    loopNotifier.onBPointReached = () {
      final plState = ref.read(playlistPlayerProvider);
      if (plState.repeatMode == pl.RepeatMode.single) {
        return false; // Normal AB loop
      }
      // Auto-advance to next track
      _advanceToNext();
      return true;
    };

    loopNotifier.onTrackEnd = () {
      if (_isPlaylist) _advanceToNext();
    };
  }

  void _advanceToNext() {
    final notifier = ref.read(playlistPlayerProvider.notifier);
    final oldTrack = ref.read(playlistPlayerProvider).currentTrack;

    // Check preload BEFORE advancing (next() changes state)
    final plState = ref.read(playlistPlayerProvider);
    final nextIdx = plState.peekNextTrackIndex();
    final isPreloaded =
        _preloadedTrackIndex != null && nextIdx == _preloadedTrackIndex;

    final changed = notifier.next();
    if (!changed) {
      // Single repeat - seek back to start of current track
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track != null) {
        ref.read(playerProvider).seek(Duration(milliseconds: track.startMs ?? 0));
      }
      return;
    }

    final newTrack = ref.read(playlistPlayerProvider).currentTrack;
    if (newTrack == null) return;

    if (oldTrack != null && newTrack.isSameItem(oldTrack)) {
      // Same item - just seek to new region
      _preloadedTrackIndex = null;
      _loadTrackRegion(newTrack);
      _startPreloadMonitor();
    } else if (isPreloaded) {
      // Different item, preloaded - swap players!
      _swapToPreloaded(newTrack);
      _loadTrackRegion(newTrack);
      _startPreloadMonitor();
    } else {
      // Different item, not preloaded - full reload
      _cancelPreload();
      _preloadCheckTimer?.cancel();
      _loadItem();
    }
  }

  void _advanceToPrev() {
    final notifier = ref.read(playlistPlayerProvider.notifier);
    final oldTrack = ref.read(playlistPlayerProvider).currentTrack;
    final changed = notifier.prev();
    if (!changed) return;
    _cancelPreload();
    _preloadCheckTimer?.cancel();
    _switchToCurrentTrack(oldTrack);
  }

  void _switchToCurrentTrack(PlaylistTrack? oldTrack) {
    final newTrack = ref.read(playlistPlayerProvider).currentTrack;
    if (newTrack == null) return;

    _cancelPreload();
    if (oldTrack != null && newTrack.isSameItem(oldTrack)) {
      // Same LoopItem - just seek and update loop points
      _loadTrackRegion(newTrack);
      _startPreloadMonitor();
    } else {
      // Different LoopItem - full reload
      _preloadCheckTimer?.cancel();
      _loadItem();
    }
  }

  void _loadTrackRegion(PlaylistTrack track) {
    final notifier = ref.read(loopProvider.notifier);
    if (track.hasRegion) {
      notifier.setPointA(
          track.startMs != null ? Duration(milliseconds: track.startMs!) : null);
      notifier.setPointB(
          track.endMs != null ? Duration(milliseconds: track.endMs!) : null);
      if (!ref.read(loopProvider).enabled) notifier.toggleEnabled();
    } else {
      notifier.reset();
    }
    if (track.startMs != null) {
      ref.read(playerProvider).seek(Duration(milliseconds: track.startMs!));
    }
    _setupPlaylistCallbacks();
    if (mounted) setState(() {});
  }

  /// パネルからのトラック選択：プリロード済みなら即切替、未準備なら裏読み込み開始
  void _requestTrack(int trackIndex) {
    final plState = ref.read(playlistPlayerProvider);
    final currentIdx = plState.currentTrackIndex;

    // 再生中のトラック
    if (trackIndex == currentIdx) return;

    // プリロード済み → 即スワップ
    if (_preloadedTrackIndex == trackIndex) {
      final notifier = ref.read(playlistPlayerProvider.notifier);
      notifier.jumpTo(trackIndex);
      final newTrack = ref.read(playlistPlayerProvider).currentTrack;
      if (newTrack != null) {
        _swapToPreloaded(newTrack);
        _loadTrackRegion(newTrack);
        _setupPlaylistCallbacks();
        _startPreloadMonitor();
      }
      return;
    }

    // 同じアイテム（異なるリージョン）→ 直接ジャンプ
    final targetTrack = plState.tracks[trackIndex];
    final currentTrack = plState.currentTrack;
    if (currentTrack != null && targetTrack.isSameItem(currentTrack)) {
      final notifier = ref.read(playlistPlayerProvider.notifier);
      notifier.jumpTo(trackIndex);
      _loadTrackRegion(
          ref.read(playlistPlayerProvider).currentTrack!);
      return;
    }

    // 未準備 → 既存プリロードをキャンセルして裏で読み込み開始
    _cancelPreload();
    _preloadNextTrack(trackIndex);
  }

  // --- Preload ---

  void _cancelPreload() {
    _preloadGeneration++; // 実行中のプリロードを無効化
    _preloadedTrackIndex = null;
    _preloadingTargetIndex = null;
    _isPreloading = false;
  }

  void _startPreloadMonitor() {
    _preloadCheckTimer?.cancel();
    _cancelPreload();

    if (!_isPlaylist) return;

    _preloadCheckTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkPreload(),
    );
  }

  void _checkPreload() {
    if (!mounted || !_isPlaylist) return;
    if (_isPreloading || _preloadedTrackIndex != null) return;

    final player = ref.read(playerProvider);
    final position = player.state.position;
    final duration = player.state.duration;

    if (duration <= Duration.zero) return;

    final remaining = duration - position;
    final thresholdSec = duration.inSeconds > 120 ? 30 : 10;

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

      final preloadPlayer = ref.read(preloadPlayerProvider);
      StreamManifest? manifest;

      if (nextTrack.item.sourceType == 'youtube') {
        final ytService = ref.read(youtubeServiceProvider);
        manifest = await ytService.getManifestWithFallback(
            nextTrack.item.videoId!);

        if (isStale()) return;

        final muxed = manifest!.muxed.sortByVideoQuality();
        String streamUrl;
        if (muxed.isNotEmpty) {
          streamUrl = muxed.last.url.toString();
        } else {
          final videoOnly = manifest!.videoOnly.sortByVideoQuality();
          if (videoOnly.isEmpty) return;
          streamUrl = videoOnly.last.url.toString();
        }

        await preloadPlayer.open(Media(streamUrl), play: false);
      } else {
        await preloadPlayer.open(Media(nextTrack.item.uri), play: false);
      }

      if (isStale()) return;

      // Wait for metadata (duration) by briefly playing
      if (preloadPlayer.state.duration == Duration.zero) {
        await preloadPlayer.setVolume(0);
        await preloadPlayer.play();
        for (var i = 0;
            i < 30 &&
                preloadPlayer.state.duration == Duration.zero &&
                !isStale();
            i++) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (isStale()) return;
        await preloadPlayer.pause();
        await preloadPlayer.setVolume(ref.read(playerProvider).state.volume);
      }

      // Seek to start position
      if (nextTrack.startMs != null) {
        await preloadPlayer.seek(Duration(milliseconds: nextTrack.startMs!));
      } else {
        await preloadPlayer.seek(Duration.zero);
      }

      // Set speed
      if (nextTrack.item.speed != 1.0) {
        await preloadPlayer.setRate(nextTrack.item.speed);
      }

      if (isStale()) return;
      _preloadedTrackIndex = nextIdx;
      if (mounted) setState(() {});

      // --- 波形の先行読み込み（並行） ---
      final itemId = nextTrack.item.id;
      if (!_waveformCache.containsKey(itemId)) {
        _preloadWaveform(nextTrack, manifest, gen);
      }
    } catch (_) {
      if (gen == _preloadGeneration) _preloadedTrackIndex = null;
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
      List<double>? waveform;

      if (item.sourceType != 'youtube') {
        waveform = await service.generateForLocalFile(item.uri, 4000);
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
              waveform = await service.generateFromUrl(tempFile.path, 4000);
            } finally {
              try { await tempFile.delete(); } catch (_) {}
            }
          }
        }
      }

      if (waveform != null && waveform.isNotEmpty && gen == _preloadGeneration) {
        _waveformCache[item.id] = waveform;
      }
    } catch (_) {
      // 波形プリロード失敗は無視（再生時に再試行される）
    }
  }

  void _swapToPreloaded(PlaylistTrack newTrack) {
    // 実行中のプリロードを無効化（スワップ後にプレーヤーを触らせない）
    _cancelPreload();

    // Save reference to old player before swap
    final oldPlayer = ref.read(playerProvider);

    // Update video source (before swap so UI has it ready)
    final item = newTrack.item;
    ref.read(videoSourceProvider.notifier).state = VideoSource(
      type: item.sourceType == 'youtube'
          ? VideoSourceType.youtube
          : VideoSourceType.local,
      uri: item.uri,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );

    // Swap active slot
    final currentSlot = ref.read(activeSlotProvider);
    ref.read(activeSlotProvider.notifier).state =
        currentSlot == ActiveSlot.a ? ActiveSlot.b : ActiveSlot.a;

    // Stop old player (now the preload player)
    oldPlayer.stop();

    // Play new active player
    ref.read(playerProvider).play();

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
    setState(() {
      _loadingProgress = progress;
      _loadingStatus = status;
    });
  }

  Future<void> _loadItem() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _loadingProgress = 0;
      _loadingStatus = '準備中...';
      _lastStepTime = DateTime.now();
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
      if (item.sourceType == 'youtube') {
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
      }
    }
  }

  Future<void> _loadYouTube(LoopItem item) async {
    await _setProgress(0.15, 'ストリーム情報を解析中...');
    final ytService = ref.read(youtubeServiceProvider);
    final manifest =
        await ytService.getManifestWithFallback(item.videoId!);

    if (!mounted) return;
    await _setProgress(0.35, '最適な品質を選択中...');
    final muxed = manifest.muxed.sortByVideoQuality();
    String streamUrl;
    if (muxed.isNotEmpty) {
      streamUrl = muxed.last.url.toString();
    } else {
      final videoOnly = manifest.videoOnly.sortByVideoQuality();
      if (videoOnly.isEmpty) throw Exception('再生可能なストリームがありません');
      streamUrl = videoOnly.last.url.toString();
    }

    if (!mounted) return;
    await _setProgress(0.50, '波形用データを取得中...');
    await _tryDownloadAudio(manifest, ytService);

    final source = VideoSource(
      type: VideoSourceType.youtube,
      uri: streamUrl,
      title: item.title,
      videoId: item.videoId,
      thumbnailUrl: item.thumbnailUrl,
    );

    if (!mounted) return;
    await _setProgress(0.75, 'プレーヤーを準備中...');
    final player = ref.read(playerProvider);
    await player.open(Media(source.uri), play: false);
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
    }

    // Setup speed
    if (item.speed != 1.0) {
      player.setRate(item.speed);
    }

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
    setState(() => _loading = false);

    // Auto-play
    player.play();

    // Start preload monitor for playlist mode
    _startPreloadMonitor();

    // Waveform
    if (source.type == VideoSourceType.local || _cachedAudioPath != null) {
      _generateWaveform(source);
    }
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
    final regions = _currentItem.effectiveRegions;
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
    final regions = item.effectiveRegions;
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    } else {
      item.pointAMs = 0;
      item.pointBMs = 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
  }

  void _addRegion() {
    if (_isPlaylist) return;
    final regions = _currentItem.effectiveRegions;
    if (regions.length >= _maxRegions) return;

    _syncRegionFromLoop();
    final position = ref.read(playerProvider).state.position;
    final region = LoopRegion(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
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

  Future<String?> _showRegionNameDialog(String initial) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('区間名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.regionNameMaxLength,
          decoration: const InputDecoration(
            hintText: '区間名を入力',
            hintStyle: kHintStyle,
            isDense: true,
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    return (result != null && result.isNotEmpty) ? result : null;
  }

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
              leading: const Icon(Icons.delete, color: Colors.red),
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
    _updatePiPPlayState(); // PiP突入前に再生状態を同期
    try {
      await _pipChannel.invokeMethod('enterPiP');
    } catch (_) {}
  }

  void _updatePiPPlayState() {
    try {
      final playing = ref.read(playerProvider).state.playing;
      _pipChannel.invokeMethod('updatePiPPlayState', {'playing': playing});
    } catch (_) {}
  }

  // --- Waveform ---

  Future<void> _generateWaveform(VideoSource source) async {
    ref.read(waveformDataProvider.notifier).state = null;
    ref.read(waveformErrorProvider.notifier).state = null;
    ref.read(waveformLoadingProvider.notifier).state = true;
    try {
      final service = WaveformService();
      await service.cancel();

      List<double>? waveform;
      if (source.type == VideoSourceType.local) {
        waveform = await service.generateForLocalFile(source.uri, 4000);
      } else if (source.videoId != null) {
        waveform = await _generateYouTubeWaveform(source, service);
      } else {
        return;
      }

      if (mounted) {
        if (waveform == null || waveform.isEmpty) {
          ref.read(waveformErrorProvider.notifier).state = '波形取得失敗';
        } else {
          ref.read(waveformDataProvider.notifier).state = waveform;
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

  Future<void> _tryDownloadAudio(
      StreamManifest manifest, dynamic ytService) async {
    try {
      final muxed = manifest.muxed.sortByVideoQuality();
      if (muxed.isEmpty) return;
      final streamInfo = muxed.first;

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/u2b_waveform_audio.tmp');
      final dataStream = ytService.yt.videos.streamsClient.get(streamInfo)
          as Stream<List<int>>;
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
        try {
          await sub.cancel().timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await sink.flush().timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await sink.close().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }

      if (bytes > 100000) {
        _cachedAudioPath = tempFile.path;
      } else {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<List<double>?> _generateYouTubeWaveform(
      VideoSource source, WaveformService service) async {
    if (_cachedAudioPath != null) {
      final path = _cachedAudioPath!;
      _cachedAudioPath = null;
      try {
        return await service.generateFromUrl(path, 4000);
      } finally {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }

    final ytService = ref.read(youtubeServiceProvider);
    try {
      final manifest = await ytService
          .getManifestWithFallback(source.videoId!)
          .timeout(const Duration(seconds: 10));
      await _tryDownloadAudio(manifest, ytService);
    } catch (_) {}

    if (_cachedAudioPath != null) {
      final path = _cachedAudioPath!;
      _cachedAudioPath = null;
      try {
        return await service.generateFromUrl(path, 4000);
      } finally {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    return null;
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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                track.displayName,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold),
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
                  _requestTrack(trackIndex);
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
            if (!isCurrent && widget.playlistId != null)
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
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showTrackTagEditor(PlaylistTrack track) {
    final tags = ref.read(tagsProvider);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
    final removed = ref
        .read(playlistPlayerProvider.notifier)
        .removeTrack(trackIndex);
    if (removed && widget.playlistId != null) {
      await ref
          .read(playlistsProvider.notifier)
          .removeItem(widget.playlistId!, track.item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('「${track.item.title}」を削除しました'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // --- Playlist panel (inline) ---

  Widget _buildPlaylistPanel(double bottomInset) {
    final plState = ref.watch(playlistPlayerProvider);
    final currentIdx = plState.currentTrackIndex;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey.shade800, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Track list
          Flexible(
            child: ListView.builder(
              padding: EdgeInsets.only(bottom: bottomInset),
              itemCount: plState.tracks.length,
              itemBuilder: (ctx, i) {
                final track = plState.tracks[i];
                final isCurrent = i == currentIdx;

                // Status indicator
                Widget statusWidget;
                if (isCurrent) {
                  statusWidget = const Icon(Icons.play_arrow,
                      color: AppTheme.accentGreen, size: 16);
                } else if (_isPreloading &&
                    _preloadingTargetIndex == i) {
                  statusWidget = const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.orange),
                  );
                } else if (_preloadedTrackIndex == i) {
                  statusWidget = const Icon(Icons.check_circle_outline,
                      color: AppTheme.accentGreen, size: 16);
                } else {
                  statusWidget = Text(
                    '${i + 1}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey),
                    textAlign: TextAlign.center,
                  );
                }

                return InkWell(
                  onTap: () => _requestTrack(i),
                  onLongPress: () => _showTrackMenu(i, track),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(width: 24, child: statusWidget),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            track.displayName,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isCurrent
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isCurrent
                                  ? AppTheme.accentGreen
                                  : track.enabled
                                      ? null
                                      : Colors.grey,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (track.hasRegion)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              '${track.startMs != null ? TimeUtils.formatShort(Duration(milliseconds: track.startMs!)) : '--:--'}'
                              ' - '
                              '${track.endMs != null ? TimeUtils.formatShort(Duration(milliseconds: track.endMs!)) : '--:--'}',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    if (_isInPiP) return _buildPiPView();
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    // Watch playlist provider for reactivity
    final plState = _isPlaylist ? ref.watch(playlistPlayerProvider) : null;
    final displayTitle = _isPlaylist
        ? (plState?.currentTrack?.displayName ?? _currentItem.title)
        : _currentItem.title;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isPlaylist && widget.playlistName != null)
              Text(
                widget.playlistName!,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              displayTitle,
              style: const TextStyle(fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          if (_isPlaylist)
            IconButton(
              icon: Icon(
                _hideVideo ? Icons.videocam_off : Icons.videocam,
                size: 20,
                color: _hideVideo ? Colors.grey : null,
              ),
              onPressed: () => setState(() => _hideVideo = !_hideVideo),
              tooltip: _hideVideo ? '動画を表示' : '動画を非表示',
            ),
          IconButton(
            icon: const Icon(Icons.picture_in_picture_alt, size: 22),
            onPressed: _enterPiP,
            tooltip: 'ピクチャーインピクチャー',
          ),
        ],
      ),
      body: _loading
          ? _buildLoadingView()
          : _loadError != null
              ? _buildErrorView()
              : _buildPlayerView(bottomInset),
    );
  }

  Widget _buildPiPView() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _hideVideo
          ? const SizedBox.shrink()
          : const Center(child: VideoPlayerWidget()),
    );
  }

  Widget _buildLoadingView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _currentItem.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _loadingProgress),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              builder: (context, value, _) {
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: value,
                        minHeight: 6,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _loadingStatus,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            const Text('読み込み失敗',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              _loadError!,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadItem,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerView(double bottomInset) {
    final regions = _currentItem.effectiveRegions;
    final loop = ref.watch(loopProvider);

    // プレイリスト+パネル表示: 固定レイアウト（スクロール不要）
    if (_isPlaylist && _showPlaylistPanel) {
      return Column(
        children: [
          if (!_hideVideo) const VideoPlayerWidget(),
          const PlayerControls(),
          LoopSeekbar(
            compact: _compactSeekbar,
            onToggleCompact: () =>
                setState(() => _compactSeekbar = !_compactSeekbar),
            allowMarkerDrag: false,
          ),
          _buildPlaylistControls(),
          Expanded(child: _buildPlaylistPanel(bottomInset)),
        ],
      );
    }

    // 通常: スクロール可能レイアウト
    return SingleChildScrollView(
      child: Column(
        children: [
          if (!(_isPlaylist && _hideVideo)) const VideoPlayerWidget(),
          const PlayerControls(),
          LoopSeekbar(
            compact: _compactSeekbar,
            onToggleCompact: () =>
                setState(() => _compactSeekbar = !_compactSeekbar),
            allowMarkerDrag: !_isPlaylist && _editMode,
          ),

          // Region + Loop controls (single mode only)
          if (!_isPlaylist) _buildRegionAndLoopPanel(regions, loop),

          // Playlist controls
          if (_isPlaylist) _buildPlaylistControls(),

          SizedBox(height: _isPlaylist ? bottomInset : 24 + bottomInset),
        ],
      ),
    );
  }

  // --- Region + Loop panel (editor-style 2-panel layout) ---

  Widget _buildRegionAndLoopPanel(
      List<LoopRegion> regions, LoopState loop) {
    final notifier = ref.read(loopProvider.notifier);
    final theme = Theme.of(context);
    final hasSource = ref.watch(videoSourceProvider) != null;

    String stepLabel(double s) =>
        s < 1 ? '${s}s' : '${s.toInt()}s';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // === Left: Region list ===
              SizedBox(
                width: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 「全体」+ 区間追加ボタン
                    InkWell(
                      onTap: _clearRegion,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 5, horizontal: 4),
                        decoration: BoxDecoration(
                          color: _activeRegionIdx == -1
                              ? theme.colorScheme.primary
                                  .withValues(alpha: 0.15)
                              : null,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _activeRegionIdx == -1
                                ? theme.colorScheme.primary
                                    .withValues(alpha: 0.5)
                                : Colors.transparent,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '全体',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: _activeRegionIdx == -1
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: _activeRegionIdx == -1
                                          ? theme.colorScheme.primary
                                          : null,
                                    ),
                                  ),
                                ),
                                if (regions.length < _maxRegions)
                                  GestureDetector(
                                    onTap: _addRegion,
                                    child: Icon(
                                        Icons.add_circle_outline,
                                        size: 16,
                                        color: Colors.grey.shade500),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 1),
                            Text(
                              'デフォルト',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (regions.isNotEmpty)
                      Divider(
                          height: 1,
                          color: theme.dividerColor
                              .withValues(alpha: 0.3)),
                    for (var i = 0; i < regions.length; i++) ...[
                      _buildRegionTile(
                        name: regions[i].name,
                        isActive: i == _activeRegionIdx,
                        pointAMs: regions[i].pointAMs,
                        pointBMs: regions[i].pointBMs,
                        onTap: () => _selectRegion(i),
                        onLongPress: () => _showRegionMenu(i),
                        theme: theme,
                      ),
                      if (i < regions.length - 1)
                        Divider(
                            height: 1,
                            color: theme.dividerColor
                                .withValues(alpha: 0.3)),
                    ],
                  ],
                ),
              ),
              VerticalDivider(
                width: 16,
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
                              size: 16,
                            ),
                            label: Text(
                              loop.enabled ? 'Loop ON' : 'Loop OFF',
                              style: const TextStyle(fontSize: 11),
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
                        if (loop.hasBothPoints)
                          Text(
                            '${((loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() / 1000).toStringAsFixed(1)}s',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500),
                          ),
                        // Edit toggle (hidden when 全体 selected)
                        if (_activeRegionIdx >= 0) ...[
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: IconButton(
                              icon: Icon(
                                _editMode ? Icons.check : Icons.edit,
                                size: 13,
                                color: _editMode
                                    ? AppTheme.accentGreen
                                    : Colors.grey[600],
                              ),
                              onPressed: _editMode
                                  ? _finishEdit
                                  : () => setState(
                                      () => _editMode = true),
                              padding: EdgeInsets.zero,
                              tooltip: _editMode
                                  ? '編集完了'
                                  : 'AB区間を編集',
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),

                    // --- Edit mode: full A/B controls ---
                    if (_editMode) ...[
                      LoopControls.buildPointRow(
                        label: 'A',
                        color: AppTheme.pointAColor,
                        time: loop.pointA,
                        stepLabel: stepLabel(_editStep),
                        onSet: hasSource
                            ? () => notifier.setPointA(
                                ref.read(playerProvider).state.position)
                            : null,
                        onTimeTap: loop.hasA
                            ? () => ref
                                .read(playerProvider)
                                .seek(loop.pointA!)
                            : null,
                        onMinus: () {
                          if (loop.hasA) {
                            notifier.setPointA(loop.pointA! -
                                Duration(
                                    milliseconds:
                                        (_editStep * 1000).round()));
                          }
                        },
                        onPlus: () {
                          if (loop.hasA) {
                            notifier.setPointA(loop.pointA! +
                                Duration(
                                    milliseconds:
                                        (_editStep * 1000).round()));
                          }
                        },
                      ),
                      // Swap button (A > B)
                      if (loop.hasBothPoints &&
                          loop.pointA!.compareTo(loop.pointB!) > 0)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 2),
                          child: SizedBox(
                            height: 24,
                            child: TextButton.icon(
                              onPressed: () => notifier.swapPoints(),
                              icon: Icon(Icons.swap_vert,
                                  size: 14,
                                  color: Colors.amber.shade300),
                              label: Text('A⇔B 入れ替え',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.amber.shade300)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 6),
                      LoopControls.buildPointRow(
                        label: 'B',
                        color: AppTheme.pointBColor,
                        time: loop.pointB,
                        stepLabel: stepLabel(_editStep),
                        onSet: hasSource
                            ? () => notifier.setPointB(
                                ref.read(playerProvider).state.position)
                            : null,
                        onTimeTap: loop.hasB
                            ? () => ref
                                .read(playerProvider)
                                .seek(loop.pointB!)
                            : null,
                        onMinus: () {
                          if (loop.hasB) {
                            notifier.setPointB(loop.pointB! -
                                Duration(
                                    milliseconds:
                                        (_editStep * 1000).round()));
                          }
                        },
                        onPlus: () {
                          if (loop.hasB) {
                            notifier.setPointB(loop.pointB! +
                                Duration(
                                    milliseconds:
                                        (_editStep * 1000).round()));
                          }
                        },
                      ),
                      const SizedBox(height: 6),
                      // Step selector (editor-style)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('Step',
                              style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 0.5,
                                  color: Colors.grey.shade500)),
                          const SizedBox(width: 5),
                          ...LoopControls.steps.map((s) {
                            final isSelected = _editStep == s;
                            final label = stepLabel(s);
                            return Padding(
                              padding: const EdgeInsets.only(left: 3),
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => _editStep = s),
                                child: Container(
                                  height: 22,
                                  padding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 6),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Colors.grey.shade800
                                        : Colors.transparent,
                                    borderRadius:
                                        BorderRadius.circular(11),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: isSelected
                                          ? Colors.grey.shade300
                                          : Colors.grey.shade600,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ] else if (_activeRegionIdx == -1) ...[
                      // --- 全体: AB区間設定ボタン ---
                      if (regions.length < _maxRegions)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8),
                          child: SizedBox(
                            width: double.infinity,
                            height: 32,
                            child: OutlinedButton.icon(
                              onPressed: _addRegion,
                              icon: Icon(Icons.add, size: 14,
                                  color: Colors.grey.shade400),
                              label: Text('AB区間を設定する',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade400)),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                    color: Colors.grey.shade700),
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(6)),
                              ),
                            ),
                          ),
                        ),
                    ] else ...[
                      // --- Non-edit: read-only A/B display ---
                      _buildPointDisplay(
                          'A', AppTheme.pointAColor, loop.pointA),
                      const SizedBox(height: 6),
                      _buildPointDisplay(
                          'B', AppTheme.pointBColor, loop.pointB),
                    ],

                    // Gap slider (when loop enabled, non-edit mode only)
                    if (loop.enabled && !_editMode) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text('Gap:',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          Expanded(
                            child: SliderTheme(
                              data: const SliderThemeData(
                                trackHeight: 2,
                                thumbShape: RoundSliderThumbShape(
                                    enabledThumbRadius: 6),
                                overlayShape:
                                    RoundSliderOverlayShape(
                                        overlayRadius: 12),
                              ),
                              child: Slider(
                                value: loop.gapSeconds,
                                min: 0,
                                max: 10,
                                divisions: 20,
                                onChanged: (v) =>
                                    notifier.setGap(v),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 30,
                            child: Text(
                              '${loop.gapSeconds.toStringAsFixed(1)}s',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
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

  Widget _buildRegionTile({
    required String name,
    required bool isActive,
    int? pointAMs,
    int? pointBMs,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    required ThemeData theme,
  }) {
    String timeText;
    if (pointAMs != null || pointBMs != null) {
      final aStr = pointAMs != null
          ? TimeUtils.formatShort(Duration(milliseconds: pointAMs))
          : '--:--';
      final bStr = pointBMs != null
          ? TimeUtils.formatShort(Duration(milliseconds: pointBMs))
          : '--:--';
      timeText = '$aStr - $bStr';
      if (pointAMs != null && pointBMs != null) {
        final durationSec = (pointBMs - pointAMs).abs() / 1000;
        timeText += ' (${durationSec.toStringAsFixed(1)}s)';
      }
    } else {
      timeText = '未設定';
    }

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? theme.colorScheme.primary : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              timeText,
              style: TextStyle(
                fontSize: 10,
                color: (pointAMs != null || pointBMs != null)
                    ? Colors.grey.shade400
                    : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPointDisplay(
      String label, Color color, Duration? time) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: color)),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: time != null
              ? () => ref.read(playerProvider).seek(time)
              : null,
          child: Text(
            TimeUtils.formatNullable(time),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              decoration:
                  time != null ? TextDecoration.underline : null,
              decorationColor: color.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistControls() {
    final plState = ref.watch(playlistPlayerProvider);
    final currentTrack = plState.currentTrack;
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
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          children: [
            // Controls row: shuffle, prev, track info, next, repeat
            Row(
              children: [
                // Shuffle
                IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    size: 22,
                    color: plState.shuffle
                        ? AppTheme.accentGreen
                        : Colors.grey,
                  ),
                  onPressed: () => ref
                      .read(playlistPlayerProvider.notifier)
                      .toggleShuffle(),
                  tooltip: 'シャッフル',
                  visualDensity: VisualDensity.compact,
                ),
                // Prev
                IconButton(
                  icon: const Icon(Icons.skip_previous, size: 28),
                  onPressed: plState.hasPrev ? _advanceToPrev : null,
                  visualDensity: VisualDensity.compact,
                ),
                // Track info
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(
                        () => _showPlaylistPanel = !_showPlaylistPanel),
                    child: Column(
                      children: [
                        Text(
                          currentIdx != null
                              ? '${currentIdx + 1} / ${plState.trackCount}'
                              : '- / ${plState.trackCount}',
                          style: const TextStyle(fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        if (currentTrack != null)
                          Text(
                            currentTrack.displayName,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ),
                // Next
                IconButton(
                  icon: const Icon(Icons.skip_next, size: 28),
                  onPressed: plState.hasNext ? _advanceToNext : null,
                  visualDensity: VisualDensity.compact,
                ),
                // Repeat mode
                IconButton(
                  icon: Icon(repeatIcon, size: 22, color: repeatColor),
                  onPressed: () => ref
                      .read(playlistPlayerProvider.notifier)
                      .cycleRepeatMode(),
                  tooltip: switch (plState.repeatMode) {
                    pl.RepeatMode.none => 'リピートなし',
                    pl.RepeatMode.all => '全曲リピート',
                    pl.RepeatMode.single => '1曲リピート',
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            // Track list button
            InkWell(
              onTap: () => setState(
                  () => _showPlaylistPanel = !_showPlaylistPanel),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _showPlaylistPanel
                          ? Icons.keyboard_arrow_down
                          : Icons.queue_music,
                      size: 16,
                      color: Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _showPlaylistPanel
                          ? 'トラック一覧を閉じる'
                          : 'トラック一覧を表示',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
