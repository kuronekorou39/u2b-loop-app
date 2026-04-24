import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/tips.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';
import '../providers/loading_animation_provider.dart';
import '../services/export_service.dart';
import '../services/waveform_service.dart';
import '../widgets/loading_animations/loading_animation_widget.dart';
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

  // 横画面
  bool _isFullscreen = false;
  bool _showFullscreenOverlay = true;
  bool _showLandscapePanel = true;
  Timer? _overlayHideTimer;
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
    // Init regions from item (エディタは最低1区間で開始)
    final effective = _item.effectiveRegions;
    _regions = effective.map((r) => r.copyWith()).toList();
    if (_regions.isEmpty) {
      _regions.add(LoopRegion(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: '区間 1',
      ));
    }
    _selectedRegionIdx =
        widget.initialRegionIndex.clamp(0, _regions.length - 1);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ミニプレイヤーが再生中なら停止
      if (ref.read(miniPlayerProvider).active) {
        ref.read(miniPlayerProvider.notifier).deactivate();
        try {
          ref.read(playerProvider).stop();
        } catch (_) {}
      }
      ref.read(videoSourceProvider.notifier).state = null;
      ref.read(loopProvider.notifier).reset();
      ref.read(waveformDataProvider.notifier).state = null;
      ref.read(waveformLoadingProvider.notifier).state = false;
      ref.read(waveformErrorProvider.notifier).state = null;
      _loadPlayer();
    });
  }

  @override
  void dispose() {
    _overlayHideTimer?.cancel();
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    try {
      ref.read(playerProvider).stop();
    } catch (_) {}
    if (_cachedAudioPath != null) {
      try { File(_cachedAudioPath!).deleteSync(); } catch (_) {}
    }
    super.dispose();
  }

  // --- Region sync ---

  void _syncCurrentRegion() {
    if (_regions.isEmpty) return;
    final loop = ref.read(loopProvider);
    _regions[_selectedRegionIdx] = _regions[_selectedRegionIdx].copyWith(
      pointAMs: () => loop.pointA?.inMilliseconds,
      pointBMs: () => loop.pointB?.inMilliseconds,
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
    notifier.setPointA(r.pointAMs != null
        ? Duration(milliseconds: r.pointAMs!)
        : null);
    notifier.setPointB(r.pointBMs != null
        ? Duration(milliseconds: r.pointBMs!)
        : null);
  }

  static const _maxRegions = AppLimits.maxRegions;

  void _addRegion() {
    if (_regions.length >= _maxRegions) return;
    _syncCurrentRegion();
    final player = ref.read(playerProvider);
    final position = player.state.position;

    final region = LoopRegion(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: '区間 ${_regions.length + 1}',
      pointAMs: position.inMilliseconds,
      pointBMs: null,
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
          maxLength: AppLimits.regionNameMaxLength,
          decoration: const InputDecoration(
            hintText: '区間名を入力',
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
    final manifest =
        await ytService.getManifestWithFallback(_item.videoId!);

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
    await _setProgress(0.50, 'プレーヤーを準備中...');

    // 波形用音声DLは再生開始後にバックグラウンドで実行
    _tryDownloadAudio(manifest, ytService);

    final source = VideoSource(
      type: VideoSourceType.youtube,
      uri: streamUrl,
      title: _item.title,
      videoId: _item.videoId,
      thumbnailUrl: _item.thumbnailUrl,
    );

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
      // Enable loop if region has both points
      final r = _regions[_selectedRegionIdx];
      if (r.hasA && r.hasB) {
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

  Future<bool> _tryDownloadAudio(
      StreamManifest manifest, dynamic ytService) async {
    final muxed = manifest.muxed.sortByVideoQuality();
    if (muxed.isEmpty) return false;
    final dataStream = ytService.yt.videos.streamsClient.get(muxed.first)
        as Stream<List<int>>;
    final path = await WaveformService().downloadAudioToTemp(dataStream);
    if (path != null) {
      _cachedAudioPath = path;
      return true;
    }
    return false;
  }

  Future<List<double>?> _generateYouTubeWaveform(
      VideoSource source, WaveformService service) async {
    if (_cachedAudioPath != null) {
      final path = _cachedAudioPath!;
      _cachedAudioPath = null;
      return await service.generateFromCachedAudio(path);
    }

    final ytService = ref.read(youtubeServiceProvider);
    final manifest = await ytService
        .getManifestWithFallback(source.videoId!)
        .timeout(const Duration(seconds: 30));
    final ok = await _tryDownloadAudio(manifest, ytService);
    if (!ok) return null;

    final path = _cachedAudioPath!;
    _cachedAudioPath = null;
    return await service.generateFromCachedAudio(path);
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
        _item.pointAMs = _regions.first.pointAMs ?? 0;
        _item.pointBMs = _regions.first.pointBMs ?? 0;
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

  // --- Export ---

  void _showExportDialog() {
    final loop = ref.read(loopProvider);
    if (!loop.hasBothPoints) return;

    final textTheme = Theme.of(context).textTheme;
    final region = _regions[_selectedRegionIdx];
    final aStr = TimeUtils.formatShort(loop.pointA!);
    final bStr = TimeUtils.formatShort(loop.pointB!);
    final durationSec =
        (loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() /
            1000;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('区間を書き出し'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${region.name}: $aStr - $bStr (${durationSec.toStringAsFixed(1)}s)',
                style: textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.xl),
            Text('形式を選択:',
                style: textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _executeExport(ExportFormat.audioOnly);
            },
            icon: const Icon(Icons.audiotrack, size: AppIconSizes.s),
            label: const Text('音声のみ'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _executeExport(ExportFormat.mp4);
            },
            icon: const Icon(Icons.videocam, size: AppIconSizes.s),
            label: const Text('MP4'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeExport(ExportFormat format) async {
    final loop = ref.read(loopProvider);
    if (!loop.hasBothPoints) return;

    final source = ref.read(videoSourceProvider);
    if (source == null) return;

    // Get input URI
    // ローカルファイルはアイテムの元URIを使用（source.uriはプレーヤー用）
    final inputUri = source.type == VideoSourceType.local
        ? _item.uri
        : source.uri;

    final startMs = loop.pointA!.inMilliseconds;
    final endMs = loop.pointB!.inMilliseconds;
    final region = _regions[_selectedRegionIdx];

    // Show progress
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
                width: AppIconSizes.s,
                height: AppIconSizes.s,
                child:
                    CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: AppSpacing.lg),
            Text('書き出し中...'),
          ],
        ),
        duration: Duration(seconds: 30),
      ),
    );

    final service = ExportService();
    final result = await service.exportRegion(
      inputUri: inputUri,
      startMs: startMs,
      endMs: endMs,
      format: format,
      title: '${_item.title}_${region.name}',
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('書き出し失敗: ${result.error}')),
      );
      return;
    }

    // Save to user-selected location
    final ext = format == ExportFormat.audioOnly ? 'm4a' : 'mp4';
    final safeTitle = '${_item.title}_${region.name}'
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final tempFile = File(result.outputPath!);
    final bytes = await tempFile.readAsBytes();

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '書き出し先を選択',
      fileName: '$safeTitle.$ext',
      bytes: Uint8List.fromList(bytes),
    );

    // Clean up temp file
    try {
      await tempFile.delete();
    } catch (_) {}

    if (savePath != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('書き出し完了')),
      );
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
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_loading || !_hasChanges) {
          Navigator.of(context).pop();
          return;
        }
        if (await _confirmDiscard()) {
          if (!context.mounted) return;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: _isFullscreen &&
                MediaQuery.orientationOf(context) == Orientation.landscape
            ? null
            : AppBar(
          title: Text(
            'AB設定 - ${_item.title}',
            style: textTheme.bodyLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (!_loading && _loadError == null) _buildWaveformAction(),
            if (!_loading && _loadError == null && _hasChanges)
              _buildSaveButton(),
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
        padding: EdgeInsets.all(AppSpacing.lg),
        child: SizedBox(
          width: AppIconSizes.lg,
          height: AppIconSizes.lg,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return TextButton.icon(
      onPressed: _save,
      icon: const Icon(Icons.save, size: AppIconSizes.sm),
      label: const Text('保存'),
    );
  }

  Widget _buildWaveformAction() {
    final textTheme = Theme.of(context).textTheme;
    final waveform = ref.watch(waveformDataProvider);
    final loading = ref.watch(waveformLoadingProvider);
    final error = ref.watch(waveformErrorProvider);

    if (loading && waveform == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: AppIconSizes.xs,
              height: AppIconSizes.xs,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text('波形取得中',
                style: textTheme.bodySmall),
          ],
        ),
      );
    }

    if (waveform == null && !loading) {
      final source = ref.read(videoSourceProvider);
      return IconButton(
        icon: Icon(Icons.graphic_eq,
            size: AppIconSizes.md, color: error != null ? Colors.orange : Colors.grey),
        tooltip: error != null ? '$error（タップで再取得）' : '波形を取得',
        onPressed: () {
          if (source != null) _generateWaveform(source);
        },
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildLoadingView() {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: LoadingAnimationView(
            type: ref.read(loadingAnimationProvider),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _item.title,
                  style: textTheme.titleSmall!.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xxl),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: _loadingProgress),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOut,
                  builder: (context, value, _) {
                    return Column(
                      children: [
                        ClipRRect(
                          borderRadius: AppRadius.borderXs,
                          child: LinearProgressIndicator(
                            value: value,
                            minHeight: 6,
                            backgroundColor: colorScheme.surfaceContainerHighest,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Text(
                            _loadingStatus,
                            key: ValueKey(_loadingStatus),
                            style: textTheme.bodyMedium!.copyWith(
                              color: colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    );
              },
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'Tip: ${getRandomTip()}',
              style: textTheme.bodySmall!.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.35),
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorView() {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: AppIconSizes.xxl, color: Colors.orange),
            const SizedBox(height: AppSpacing.xl),
            Text(
              '読み込み失敗',
              style: textTheme.displaySmall!.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              _loadError!,
              style: textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xxl),
            FilledButton.icon(
              onPressed: _loadPlayer,
              icon: const Icon(Icons.refresh, size: AppIconSizes.sm),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorView(double bottomInset) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (isLandscape) {
      return _buildLandscapeEditorView(bottomInset);
    }

    return Column(
      children: [
        VideoPlayerWidget(onFullscreen: _enterFullscreen),
        const PlayerControls(),
        const LoopSeekbar(),
        // Unified region + AB controls panel
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, max(bottomInset + AppSpacing.xl, 40)),
            child: _buildUnifiedPanel(),
          ),
        ),
      ],
    );
  }

  void _enterFullscreen() {
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    if (isPortrait) {
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
    setState(() => _isFullscreen = false);
    _overlayHideTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
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

  /// フルスクリーンボタン（動画右下に配置、共通）
  Widget _buildFullscreenButton(VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: AppRadius.borderXs,
        ),
        child: const Icon(Icons.fullscreen,
            color: Colors.white, size: AppIconSizes.md),
      ),
    );
  }

  Widget _buildLandscapeEditorView(double bottomInset) {
    if (_isFullscreen) return _buildFullscreenEditorView();

    // 縦に戻ったらフルスクリーン解除
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (!isLandscape && _isFullscreen) {
      _isFullscreen = false;
      _overlayHideTimer?.cancel();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    return SafeArea(
      child: Row(
        children: [
          // === 左（60%）: 動画 + コントロール + 波形 ===
          Expanded(
            flex: _showLandscapePanel ? 3 : 1,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      GestureDetector(
                        onDoubleTap: _enterFullscreen,
                        child: const VideoPlayerWidget(useAspectRatio: false),
                      ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: () => setState(() =>
                                  _showLandscapePanel = !_showLandscapePanel),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  borderRadius: AppRadius.borderXs,
                                ),
                                child: Icon(
                                  _showLandscapePanel
                                      ? Icons.chevron_right
                                      : Icons.chevron_left,
                                  color: Colors.white,
                                  size: AppIconSizes.md,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            _buildFullscreenButton(_enterFullscreen),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs, vertical: 2),
                  child: const PlayerControls(),
                ),
                const LoopSeekbar(compact: true),
              ],
            ),
          ),
          // === 右パネル（40%） ===
          if (_showLandscapePanel) ...[
            VerticalDivider(width: 1, color: Colors.grey.shade800),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: _buildUnifiedPanel(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFullscreenEditorView() {
    return Stack(
      children: [
        const Positioned.fill(
          child: VideoPlayerWidget(useAspectRatio: false),
        ),
        // タップ検知レイヤー
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleFullscreenOverlay,
            onDoubleTap: _exitFullscreen,
          ),
        ),
        // オーバーレイ
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
                      Colors.black54, Colors.transparent,
                      Colors.transparent, Colors.black54,
                    ],
                    stops: [0.0, 0.2, 0.7, 1.0],
                  ),
                ),
                child: Column(
                  children: [
                    const Spacer(),
                    // 下部コントロール
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const LoopSeekbar(compact: true),
                            const PlayerControls(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // フルスクリーン解除ボタン（右下）
        if (_showFullscreenOverlay)
          Positioned(
            right: 12,
            bottom: 12,
            child: SafeArea(
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
          ),
      ],
    );
  }

  Widget _buildUnifiedPanel() {
    final loop = ref.watch(loopProvider);
    final loopNotifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final canAdd = _regions.length < _maxRegions;

    // Sync current region values from loop provider in real-time
    if (_regions.isNotEmpty) {
      _regions[_selectedRegionIdx] = _regions[_selectedRegionIdx].copyWith(
        pointAMs: () => loop.pointA?.inMilliseconds,
        pointBMs: () => loop.pointB?.inMilliseconds,
      );
    }

    final stepLabel = loop.adjustStep < 1
        ? '${loop.adjustStep}s'
        : '${loop.adjustStep.toInt()}s';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
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
                  const SizedBox(height: AppSpacing.xs),
                  SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: OutlinedButton.icon(
                      onPressed: canAdd ? _addRegion : null,
                      icon: const Icon(Icons.add, size: AppIconSizes.xs),
                      label: Text(canAdd ? '追加' : '上限',
                          style: textTheme.labelSmall),
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
              width: AppSpacing.xl,
              thickness: 1,
              color: theme.dividerColor.withValues(alpha: 0.3),
            ),
            // Right: AB controls
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Loop toggle + duration display (top row)
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
                            size: AppIconSizes.s,
                          ),
                          label: Text(
                              loop.enabled ? 'Loop ON' : 'Loop OFF'),
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
                      if (loop.hasBothPoints)
                        Text(
                          '${((loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() / 1000).toStringAsFixed(1)}s',
                          style: textTheme.bodySmall!.copyWith(
                              color: Colors.grey.shade500),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  // Point A row
                  LoopControls.buildPointRow(
                    label: 'A',
                    color: AppTheme.pointAColor,
                    time: loop.pointA,
                    stepLabel: stepLabel,
                    onSet: hasSource
                        ? () => loopNotifier.setPointAToCurrentPosition()
                        : null,
                    onTimeTap: loop.hasA
                        ? () => ref.read(playerProvider).seek(loop.pointA!)
                        : null,
                    onMinus: () => loopNotifier.adjustPointA(-1),
                    onPlus: () => loopNotifier.adjustPointA(1),
                  ),

                  // Swap button (shown when A > B)
                  if (loop.hasBothPoints &&
                      loop.pointA!.compareTo(loop.pointB!) > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SizedBox(
                        height: 24,
                        child: TextButton.icon(
                          onPressed: () => loopNotifier.swapPoints(),
                          icon: Icon(Icons.swap_vert,
                              size: AppIconSizes.xs, color: Colors.amber.shade300),
                          label: Text('A⇔B 入れ替え',
                              style: textTheme.labelSmall!.copyWith(
                                  fontSize: 10,
                                  color: Colors.amber.shade300)),
                          style: TextButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: AppSpacing.sm),

                  // Point B row
                  LoopControls.buildPointRow(
                    label: 'B',
                    color: AppTheme.pointBColor,
                    time: loop.pointB,
                    stepLabel: stepLabel,
                    onSet: hasSource
                        ? () => loopNotifier.setPointBToCurrentPosition()
                        : null,
                    onTimeTap: loop.hasB
                        ? () => ref.read(playerProvider).seek(loop.pointB!)
                        : null,
                    onMinus: () => loopNotifier.adjustPointB(-1),
                    onPlus: () => loopNotifier.adjustPointB(1),
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  // Step selector (inline chips, right-aligned)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('Step',
                          style: textTheme.labelSmall!.copyWith(
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.5,
                              color: Colors.grey.shade500)),
                      const SizedBox(width: 5),
                      ...LoopControls.steps.map((s) {
                        final isSelected = loop.adjustStep == s;
                        final label = s < 1 ? '${s}s' : '${s.toInt()}s';
                        return Padding(
                          padding: const EdgeInsets.only(left: 3),
                          child: GestureDetector(
                            onTap: () => loopNotifier.setStep(s),
                            child: Container(
                              height: 22,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.grey.shade800
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                label,
                                style: textTheme.labelSmall!.copyWith(
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

                  const Spacer(),

                  // Export + Clear buttons (bottom)
                  Row(
                    children: [
                      TextButton.icon(
                          onPressed: loop.hasBothPoints
                              ? () => _showExportDialog()
                              : null,
                          icon: const Icon(Icons.file_download,
                              size: AppIconSizes.xs),
                          label: Text('書き出し',
                              style: textTheme.labelSmall),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md),
                            minimumSize: Size.zero,
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppTheme.accentGreen,
                          ),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed:
                            hasSource ? () => loopNotifier.reset() : null,
                        style: TextButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                          minimumSize: Size.zero,
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: Colors.grey,
                        ),
                        child: Text('クリア',
                            style: textTheme.labelSmall),
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
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    String timeText;
    if (region.hasA || region.hasB) {
      final aStr = region.hasA
          ? TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!))
          : '--:--';
      final bStr = region.hasB
          ? TimeUtils.formatShort(Duration(milliseconds: region.pointBMs!))
          : '--:--';
      timeText = '$aStr - $bStr';
      if (region.hasA && region.hasB) {
        final durationSec =
            (region.pointBMs! - region.pointAMs!).abs() / 1000;
        timeText += ' (${durationSec.toStringAsFixed(1)}s)';
      }
    } else {
      timeText = '未設定';
    }

    return InkWell(
      onTap: () => _selectRegion(index),
      onLongPress: () => _showRegionMenu(index),
      borderRadius: AppRadius.borderSm,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: AppSpacing.xs),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : null,
          borderRadius: AppRadius.borderSm,
          border: isSelected
              ? Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  width: 1)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              region.name,
              style: textTheme.labelMedium!.copyWith(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected
                    ? theme.colorScheme.primary
                    : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              timeText,
              style: textTheme.labelSmall!.copyWith(
                fontSize: 10,
                color: (region.hasA || region.hasB)
                    ? Colors.grey.shade400
                    : Colors.grey.shade600,
              ),
            ),
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
                    const Icon(Icons.delete_outline, color: Colors.red),
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
