import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/loop_state.dart';
import '../models/playlist_mode.dart' as pl;
import '../models/playlist_track.dart';
import '../models/video_source.dart';
import '../providers/loop_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_player_provider.dart';
import '../services/waveform_service.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/video_player_widget.dart';

/// 汎用プレーヤー画面。単体再生・プレイリスト再生・PiP対応。
class PlayerScreen extends ConsumerStatefulWidget {
  final LoopItem item;
  final List<LoopItem>? playlistItems;
  final int initialIndex;

  const PlayerScreen({
    super.key,
    required this.item,
    this.playlistItems,
    this.initialIndex = 0,
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

    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPiPChanged') {
        if (mounted) setState(() => _isInPiP = call.arguments as bool);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
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
            );
      }

      _loadItem();
    });
  }

  @override
  void deactivate() {
    try {
      ref.read(playerProvider).stop();
      ref.read(loopProvider.notifier).onBPointReached = null;
      ref.read(loopProvider.notifier).onTrackEnd = null;
      if (_isPlaylist) ref.read(playlistPlayerProvider.notifier).clear();
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
    final changed = notifier.next();
    if (!changed) {
      // Single repeat - seek back to start of current track
      final track = ref.read(playlistPlayerProvider).currentTrack;
      if (track != null) {
        final a = track.startMs;
        ref.read(playerProvider).seek(Duration(milliseconds: a ?? 0));
      }
      return;
    }
    _switchToCurrentTrack(oldTrack);
  }

  void _advanceToPrev() {
    final notifier = ref.read(playlistPlayerProvider.notifier);
    final oldTrack = ref.read(playlistPlayerProvider).currentTrack;
    final changed = notifier.prev();
    if (!changed) return;
    _switchToCurrentTrack(oldTrack);
  }

  void _switchToCurrentTrack(PlaylistTrack? oldTrack) {
    final newTrack = ref.read(playlistPlayerProvider).currentTrack;
    if (newTrack == null) return;

    if (oldTrack != null && newTrack.isSameItem(oldTrack)) {
      // Same LoopItem - just seek and update loop points
      _loadTrackRegion(newTrack);
    } else {
      // Different LoopItem - full reload
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

  void _jumpToTrack(int trackIndex) {
    final notifier = ref.read(playlistPlayerProvider.notifier);
    final oldTrack = ref.read(playlistPlayerProvider).currentTrack;
    notifier.jumpTo(trackIndex);
    _switchToCurrentTrack(oldTrack);
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
        await ytService.yt.videos.streamsClient.getManifest(item.videoId!);

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
    setState(() => _activeRegionIdx = -1);
    final notifier = ref.read(loopProvider.notifier);
    notifier.reset();
  }

  // --- PiP ---

  void _enterPiP() async {
    try {
      await _pipChannel.invokeMethod('enterPiP');
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
      final manifest = await ytService.yt.videos.streamsClient
          .getManifest(source.videoId!)
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

  // --- Track list bottom sheet ---

  void _showTrackList() {
    final plState = ref.read(playlistPlayerProvider);
    if (plState.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final state = ref.read(playlistPlayerProvider);
            final currentIdx = state.currentTrackIndex;

            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) {
                return Column(
                  children: [
                    // Handle bar
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[600],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            'トラック一覧',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${state.enabledCount}/${state.trackCount} 有効',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: state.tracks.length,
                        itemBuilder: (ctx, i) {
                          final track = state.tracks[i];
                          final isCurrent = i == currentIdx;

                          return ListTile(
                            dense: true,
                            leading: Checkbox(
                              value: track.enabled,
                              onChanged: (_) {
                                ref
                                    .read(playlistPlayerProvider.notifier)
                                    .toggleTrackEnabled(i);
                                setSheetState(() {});
                              },
                              visualDensity: VisualDensity.compact,
                            ),
                            title: Text(
                              track.displayName,
                              style: TextStyle(
                                fontSize: 13,
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
                            subtitle: track.hasRegion
                                ? Text(
                                    '${track.startMs != null ? TimeUtils.formatShort(Duration(milliseconds: track.startMs!)) : '--:--'}'
                                    ' - '
                                    '${track.endMs != null ? TimeUtils.formatShort(Duration(milliseconds: track.endMs!)) : '--:--'}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isCurrent
                                          ? AppTheme.accentGreen
                                              .withValues(alpha: 0.7)
                                          : Colors.grey,
                                    ),
                                  )
                                : null,
                            trailing: isCurrent
                                ? const Icon(Icons.play_arrow,
                                    color: AppTheme.accentGreen, size: 20)
                                : Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _jumpToTrack(i);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
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
        title: Text(
          displayTitle,
          style: const TextStyle(fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
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
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: VideoPlayerWidget()),
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

    return SingleChildScrollView(
      child: Column(
        children: [
          const VideoPlayerWidget(),
          const PlayerControls(),
          const LoopSeekbar(),

          // Region selector (non-playlist mode only)
          if (!_isPlaylist && regions.isNotEmpty) _buildRegionSelector(regions),

          // Loop & Gap controls
          _buildLoopControls(loop),

          // Playlist controls
          if (_isPlaylist) _buildPlaylistControls(),

          SizedBox(height: 24 + bottomInset),
        ],
      ),
    );
  }

  Widget _buildRegionSelector(List<LoopRegion> regions) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 4),
            child: Text('区間',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: regions.length + 1, // +1 for "all" / off
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  // "Full" - no loop region
                  return ChoiceChip(
                    label: const Text('全体',
                        style: TextStyle(fontSize: 12)),
                    selected: _activeRegionIdx == -1,
                    onSelected: (_) => _clearRegion(),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  );
                }
                final ri = i - 1;
                final region = regions[ri];
                final isActive = ri == _activeRegionIdx;
                return ChoiceChip(
                  label: Text(
                    '${region.name} (${region.pointAMs != null ? TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!)) : '--:--'})',
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: isActive,
                  onSelected: (_) => _selectRegion(ri),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoopControls(LoopState loop) {
    final notifier = ref.read(loopProvider.notifier);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Loop toggle + current AB display
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () => notifier.toggleEnabled(),
                  icon: Icon(
                    loop.enabled ? Icons.repeat_on : Icons.repeat,
                    size: 18,
                  ),
                  label: Text(loop.enabled ? 'ループ ON' : 'ループ OFF'),
                  style: FilledButton.styleFrom(
                    backgroundColor: loop.enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    foregroundColor:
                        loop.enabled ? Colors.black : Colors.grey,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 36),
                  ),
                ),
                const Spacer(),
                if (loop.hasPoints) ...[
                  Text(
                    TimeUtils.formatShortNullable(loop.pointA),
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.pointAColor),
                  ),
                  const Text(' - ',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text(
                    TimeUtils.formatShortNullable(loop.pointB),
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.pointBColor),
                  ),
                ],
              ],
            ),
            // Gap slider
            if (loop.enabled) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Gap:',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Expanded(
                    child: Slider(
                      value: loop.gapSeconds,
                      min: 0,
                      max: 10,
                      divisions: 20,
                      label: '${loop.gapSeconds.toStringAsFixed(1)}s',
                      onChanged: (v) => notifier.setGap(v),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${loop.gapSeconds.toStringAsFixed(1)}s',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
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
                    onTap: _showTrackList,
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
              onTap: _showTrackList,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.queue_music, size: 16, color: Colors.grey[500]),
                    const SizedBox(width: 4),
                    Text(
                      'トラック一覧を表示',
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
