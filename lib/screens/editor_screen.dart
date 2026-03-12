import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/player_provider.dart';
import '../services/waveform_service.dart';
import '../widgets/loop/loop_controls.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/video_player_widget.dart';

/// AB区間専用エディタ。LoopItem を受け取って AB 区間を編集する。
class EditorScreen extends ConsumerStatefulWidget {
  final LoopItem item;
  final int initialRegionIndex;

  const EditorScreen({
    super.key,
    required this.item,
    this.initialRegionIndex = 0,
  });

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  bool _loading = true;
  bool _saving = false;
  String _loadingStatus = '準備中...';
  double _loadingProgress = 0;
  DateTime _lastStepTime = DateTime.now();
  String? _cachedAudioPath;
  String? _loadError;

  // Region management
  late List<LoopRegion> _regions;
  int _selectedRegionIdx = 0;

  LoopItem get _item => widget.item;

  @override
  void initState() {
    super.initState();
    // Init regions from item
    final effective = _item.effectiveRegions;
    _regions = effective.map((r) => r.copyWith()).toList();
    _selectedRegionIdx =
        widget.initialRegionIndex.clamp(0, _regions.length.clamp(1, 999) - 1);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(videoSourceProvider.notifier).state = null;
      ref.read(loopProvider.notifier).reset();
      ref.read(waveformDataProvider.notifier).state = null;
      ref.read(waveformLoadingProvider.notifier).state = false;
      ref.read(waveformErrorProvider.notifier).state = null;
      _loadPlayer();
    });
  }

  @override
  void deactivate() {
    try {
      ref.read(playerProvider).stop();
    } catch (_) {}
    super.deactivate();
  }

  // --- Region sync ---

  void _syncCurrentRegion() {
    if (_regions.isEmpty) return;
    final loop = ref.read(loopProvider);
    _regions[_selectedRegionIdx] = _regions[_selectedRegionIdx].copyWith(
      pointAMs: loop.pointA.inMilliseconds,
      pointBMs: loop.pointB.inMilliseconds,
    );
  }

  void _selectRegion(int index) {
    if (index == _selectedRegionIdx) return;
    _syncCurrentRegion();
    setState(() => _selectedRegionIdx = index);
    _loadRegionIntoLoop(index);
  }

  void _loadRegionIntoLoop(int index) {
    if (index < 0 || index >= _regions.length) return;
    final r = _regions[index];
    final notifier = ref.read(loopProvider.notifier);
    notifier.setPointA(Duration(milliseconds: r.pointAMs));
    notifier.setPointB(Duration(milliseconds: r.pointBMs));
  }

  static const _maxRegions = 10;

  void _addRegion() {
    if (_regions.length >= _maxRegions) return;
    _syncCurrentRegion();
    final player = ref.read(playerProvider);
    final position = player.state.position;
    final duration = player.state.duration;
    final bMs = (position.inMilliseconds + 60000)
        .clamp(0, duration.inMilliseconds);

    final region = LoopRegion(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: '区間 ${_regions.length + 1}',
      pointAMs: position.inMilliseconds,
      pointBMs: bMs,
    );
    setState(() {
      _regions.add(region);
      _selectedRegionIdx = _regions.length - 1;
    });
    _loadRegionIntoLoop(_selectedRegionIdx);
  }

  void _renameRegion(int index) async {
    final name = await _showRegionNameDialog(_regions[index].name);
    if (name == null) return;
    setState(() {
      _regions[index] = _regions[index].copyWith(name: name);
    });
  }

  void _deleteRegion(int index) {
    if (_regions.length <= 1) return;
    setState(() {
      _regions.removeAt(index);
      if (_selectedRegionIdx >= _regions.length) {
        _selectedRegionIdx = _regions.length - 1;
      }
    });
    _loadRegionIntoLoop(_selectedRegionIdx);
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
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '区間名を入力（最大20文字）',
            isDense: true,
            border: OutlineInputBorder(),
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

  // --- Loading progress ---

  Future<void> _setProgress(double progress, String status) async {
    final elapsed = DateTime.now().difference(_lastStepTime).inMilliseconds;
    const minMs = 400;
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

  // --- Load player ---

  Future<void> _loadPlayer() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _loadingProgress = 0;
      _loadingStatus = '準備中...';
      _lastStepTime = DateTime.now();
    });

    try {
      if (_item.sourceType == 'youtube') {
        await _loadYouTube();
      } else {
        await _loadLocal();
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

  Future<void> _loadYouTube() async {
    await _setProgress(0.15, 'ストリーム情報を解析中...');
    final ytService = ref.read(youtubeServiceProvider);
    final manifest = await ytService.yt.videos.streamsClient
        .getManifest(_item.videoId!);

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
      title: _item.title,
      videoId: _item.videoId,
      thumbnailUrl: _item.thumbnailUrl,
    );

    if (!mounted) return;
    await _setProgress(0.75, 'プレーヤーを準備中...');
    final player = ref.read(playerProvider);
    await player.open(Media(source.uri), play: false);
    ref.read(videoSourceProvider.notifier).state = source;

    _restoreValues();
    await _finishLoading(source);
  }

  Future<void> _loadLocal() async {
    await _setProgress(0.30, 'ファイルを読み込み中...');
    final source = VideoSource(
      type: VideoSourceType.local,
      uri: _item.uri,
      title: _item.title,
    );

    if (!mounted) return;
    await _setProgress(0.65, 'プレーヤーを準備中...');
    final player = ref.read(playerProvider);
    await player.open(Media(_item.uri), play: false);
    ref.read(videoSourceProvider.notifier).state = source;

    _restoreValues();
    await _finishLoading(source);
  }

  void _restoreValues() {
    // Load selected region's AB into loop provider
    if (_regions.isNotEmpty) {
      _loadRegionIntoLoop(_selectedRegionIdx);
      // Enable loop if region has points
      final r = _regions[_selectedRegionIdx];
      if (r.pointAMs > 0 || r.pointBMs > 0) {
        ref.read(loopProvider.notifier).toggleEnabled();
      }
    } else if (_item.pointAMs > 0 || _item.pointBMs > 0) {
      ref.read(loopProvider.notifier)
          .setPointA(Duration(milliseconds: _item.pointAMs));
      ref.read(loopProvider.notifier)
          .setPointB(Duration(milliseconds: _item.pointBMs));
      ref.read(loopProvider.notifier).toggleEnabled();
    }
    if (_item.speed != 1.0) {
      ref.read(playerProvider).setRate(_item.speed);
    }
  }

  Future<void> _finishLoading(VideoSource source) async {
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

    if (!mounted) return;
    await _setProgress(1.0, '読み込み完了！');
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _loading = false);

    if (source.type == VideoSourceType.local || _cachedAudioPath != null) {
      _generateWaveform(source);
    }
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
      print(
          '[Waveform] 事前DL: muxed ${streamInfo.qualityLabel} ${streamInfo.size}');

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
        print(
            '[Waveform] 事前DL成功: ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB');
      } else {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    } catch (e) {
      print('[Waveform] 事前DLスキップ: $e');
    }
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

  // --- Save ---

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _syncCurrentRegion();

      final rate = ref.read(playerProvider).state.rate;
      _item.regions = List.from(_regions);
      _item.speed = rate;

      // Update pointA/B from first region for backward compat
      if (_regions.isNotEmpty) {
        _item.pointAMs = _regions.first.pointAMs;
        _item.pointBMs = _regions.first.pointBMs;
      }

      await ref.read(loopItemsProvider.notifier).update(_item);

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失敗: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _hasChanges {
    _syncCurrentRegion();
    final rate = ref.read(playerProvider).state.rate;
    if (rate != _item.speed) return true;

    // Compare regions
    final orig = _item.effectiveRegions;
    if (_regions.length != orig.length) return true;
    for (var i = 0; i < _regions.length; i++) {
      if (_regions[i].pointAMs != orig[i].pointAMs) return true;
      if (_regions[i].pointBMs != orig[i].pointBMs) return true;
      if (_regions[i].name != orig[i].name) return true;
    }
    return false;
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('変更を破棄しますか？'),
        content: const Text('保存していないAB設定があります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('戻る'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('破棄', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result == true;
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_loading || !_hasChanges) {
          Navigator.of(context).pop();
          return;
        }
        if (await _confirmDiscard() && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            'AB設定 - ${_item.title}',
            style: const TextStyle(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (!_loading && _loadError == null) _buildSaveButton(),
            if (!_loading && _loadError == null) _buildWaveformAction(),
          ],
        ),
        body: _loading
            ? _buildLoadingView()
            : _loadError != null
                ? _buildErrorView()
                : _buildEditorView(bottomInset),
      ),
    );
  }

  Widget _buildSaveButton() {
    if (_saving) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return TextButton.icon(
      onPressed: _save,
      icon: const Icon(Icons.save, size: 18),
      label: const Text('保存'),
    );
  }

  Widget _buildWaveformAction() {
    final waveform = ref.watch(waveformDataProvider);
    final loading = ref.watch(waveformLoadingProvider);
    final error = ref.watch(waveformErrorProvider);

    if (loading && waveform == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 6),
            Text('波形取得中',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }

    if (waveform == null && !loading) {
      final source = ref.read(videoSourceProvider);
      return IconButton(
        icon: Icon(Icons.graphic_eq,
            size: 20, color: error != null ? Colors.orange : Colors.grey),
        tooltip: error != null ? '$error（タップで再取得）' : '波形を取得',
        onPressed: () {
          if (source != null) _generateWaveform(source);
        },
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildLoadingView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _item.title,
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
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(
                        _loadingStatus,
                        key: ValueKey(_loadingStatus),
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
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
            Text(
              '読み込み失敗',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _loadError!,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadPlayer,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorView(double bottomInset) {
    return Column(
      children: [
        const VideoPlayerWidget(),
        const PlayerControls(),
        const LoopSeekbar(),
        // Unified region + AB controls panel
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: _buildUnifiedPanel(),
          ),
        ),
        SizedBox(height: bottomInset),
      ],
    );
  }

  Widget _buildUnifiedPanel() {
    final loop = ref.watch(loopProvider);
    final loopNotifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final theme = Theme.of(context);
    final canAdd = _regions.length < _maxRegions;

    // Sync current region values from loop provider in real-time
    if (_regions.isNotEmpty) {
      _regions[_selectedRegionIdx] = _regions[_selectedRegionIdx].copyWith(
        pointAMs: loop.pointA.inMilliseconds,
        pointBMs: loop.pointB.inMilliseconds,
      );
    }

    final stepLabel = loop.adjustStep < 1
        ? '${loop.adjustStep}s'
        : '${loop.adjustStep.toInt()}s';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left: Region list (vertical)
            SizedBox(
              width: 120,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        for (var i = 0; i < _regions.length; i++) ...[
                          _buildRegionTile(i),
                          if (i < _regions.length - 1)
                            Divider(
                                height: 1,
                                color: theme.dividerColor
                                    .withValues(alpha: 0.3)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: OutlinedButton.icon(
                      onPressed: canAdd ? _addRegion : null,
                      icon: const Icon(Icons.add, size: 14),
                      label: Text(canAdd ? '追加' : '上限',
                          style: const TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        side: BorderSide(color: Colors.grey.shade700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Separator
            VerticalDivider(
              width: 16,
              thickness: 1,
              color: theme.dividerColor.withValues(alpha: 0.3),
            ),
            // Right: AB controls
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Point A row
                  LoopControls.buildPointRow(
                    label: 'A',
                    color: AppTheme.pointAColor,
                    time: loop.pointA,
                    stepLabel: stepLabel,
                    onSet: hasSource
                        ? () => loopNotifier.setPointAToCurrentPosition()
                        : null,
                    onMinus: () => loopNotifier.adjustPointA(-1),
                    onPlus: () => loopNotifier.adjustPointA(1),
                  ),
                  const SizedBox(height: 6),

                  // Point B row
                  LoopControls.buildPointRow(
                    label: 'B',
                    color: AppTheme.pointBColor,
                    time: loop.pointB,
                    stepLabel: stepLabel,
                    onSet: hasSource
                        ? () => loopNotifier.setPointBToCurrentPosition()
                        : null,
                    onMinus: () => loopNotifier.adjustPointB(-1),
                    onPlus: () => loopNotifier.adjustPointB(1),
                  ),
                  const SizedBox(height: 8),

                  // Loop toggle + Clear + Step selector
                  Row(
                    children: [
                      SizedBox(
                        height: 28,
                        child: FilledButton.icon(
                          onPressed: hasSource
                              ? () => loopNotifier.toggleEnabled()
                              : null,
                          icon: Icon(
                            loop.enabled ? Icons.repeat_on : Icons.repeat,
                            size: 16,
                          ),
                          label: Text(
                              loop.enabled ? 'Loop ON' : 'Loop OFF',
                              style: const TextStyle(fontSize: 11)),
                          style: FilledButton.styleFrom(
                            backgroundColor: loop.enabled
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                            foregroundColor:
                                loop.enabled ? Colors.black : Colors.grey,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: Size.zero,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Clear (text button style)
                      TextButton(
                        onPressed:
                            hasSource ? () => loopNotifier.reset() : null,
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: Colors.grey,
                        ),
                        child: const Text('クリア',
                            style: TextStyle(fontSize: 11)),
                      ),
                      // Step selector
                      PopupMenuButton<double>(
                        initialValue: loop.adjustStep,
                        onSelected: (v) => loopNotifier.setStep(v),
                        padding: EdgeInsets.zero,
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade700),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(stepLabel,
                                  style: const TextStyle(fontSize: 11)),
                              const Icon(Icons.arrow_drop_down, size: 16),
                            ],
                          ),
                        ),
                        itemBuilder: (_) => LoopControls.steps
                            .map((s) => PopupMenuItem(
                                  value: s,
                                  height: 36,
                                  child: Text(
                                    s < 1 ? '${s}s' : '${s.toInt()}s',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ))
                            .toList(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegionTile(int index) {
    final region = _regions[index];
    final isSelected = index == _selectedRegionIdx;
    final hasAb = region.pointAMs > 0 || region.pointBMs > 0;

    return InkWell(
      onTap: () => _selectRegion(index),
      onLongPress: () => _showRegionMenu(index),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        decoration: isSelected
            ? BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              region.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            if (hasAb)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    TimeUtils.formatShort(
                        Duration(milliseconds: region.pointAMs)),
                    style: TextStyle(
                        fontSize: 10, color: AppTheme.pointAColor),
                  ),
                  const Text(' - ',
                      style: TextStyle(fontSize: 10, color: Colors.grey)),
                  Text(
                    TimeUtils.formatShort(
                        Duration(milliseconds: region.pointBMs)),
                    style: TextStyle(
                        fontSize: 10, color: AppTheme.pointBColor),
                  ),
                ],
              )
            else
              const Text('未設定',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
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
              title: const Text('名前を変更'),
              onTap: () {
                Navigator.pop(ctx);
                _renameRegion(index);
              },
            ),
            if (_regions.length > 1)
              ListTile(
                leading:
                    const Icon(Icons.delete, color: Colors.red),
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
}
