import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
import '../services/export_runner.dart';
import '../services/audio_analysis_service.dart';
import '../services/waveform_service.dart';
import '../widgets/loading_animations/loading_animation_widget.dart';
import '../widgets/loop/ab_edit_controls.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/loop/region_panel.dart';
import '../widgets/player/now_playing_header.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/player_shell.dart';
import '../widgets/player/single_player_bar.dart';
import '../widgets/player/video_player_widget.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/id_generator.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';

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

  /// 縦画面の中段に区間パネルを開いているか
  bool _panelOpen = false;

  LoopItem get _item => widget.item;

  @override
  void initState() {
    super.initState();
    // Init regions from item (エディタは最低1区間で開始)
    final effective = _item.effectiveRegions;
    _regions = effective.map((r) => r.copyWith()).toList();
    if (_regions.isEmpty) {
      _regions.add(LoopRegion(
        id: IdGenerator.next(),
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
      id: IdGenerator.next(),
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

  Future<String?> _showRegionNameDialog(String initial) =>
      AppDialogs.prompt(context,
          title: '区間名',
          initialValue: initial,
          hintText: '区間名を入力',
          maxLength: AppLimits.regionNameMaxLength);

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
      if (_item.isYouTube) {
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

    final source = VideoSource(
      type: VideoSourceType.youtube,
      uri: streamUrl,
      title: _item.title,
      videoId: _item.videoId,
      thumbnailUrl: _item.thumbnailUrl,
    );

    // 波形用音声DLをバックグラウンド開始→完了後に波形生成。
    // 波形が保存済み（かつ解析不要）なら DL せずにそのまま使う
    WaveformService.canSkipAudioFetch(_item).then((skip) async {
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
    // プレイヤー使い回しのため、前に再生していた曲の速度が残らないよう毎回設定
    ref.read(playerProvider).setRate(_item.speed);
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
        onPcm: AudioAnalysisService.sinkFor(
            ref.read(loopItemsProvider.notifier), _item),
        cacheKey: _item.id,
      );

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
          AppSnackBar.error('保存失敗: $e'),
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

    final region = _regions[_selectedRegionIdx];
    final aStr = TimeUtils.formatShort(loop.pointA!);
    final bStr = TimeUtils.formatShort(loop.pointB!);
    final durationSec =
        (loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() /
            1000;

    showExportFormatDialog(
      context,
      title: '${region.name} を書き出し',
      rangeText: '$aStr - $bStr (${durationSec.toStringAsFixed(1)}s)',
    ).then((format) {
      if (format == null || !mounted) return;
      _executeExport(format);
    });
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

    final region = _regions[_selectedRegionIdx];

    if (!mounted) return;
    await runExportFlow(
      context,
      inputUri: inputUri,
      startMs: loop.pointA!.inMilliseconds,
      endMs: loop.pointB!.inMilliseconds,
      format: format,
      title: '${_item.title}_${region.name}',
    );
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

  Future<bool> _confirmDiscard() => AppDialogs.confirm(context,
      title: '変更を破棄しますか？',
      message: '保存していないAB設定があります。',
      confirmLabel: '破棄',
      cancelLabel: '戻る',
      destructive: true);

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    // _hasChanges が再生速度を見ているので、速度変更だけでも再ビルドさせる
    // （watchしないと速度だけ変えたときに保存ボタンが出ない）
    ref.watch(rateProvider);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // 縦画面の編集中はガラス風（再生画面と同じ骨組み）: AppBar を透明にして背景を上まで通す
    final glassLook = !_loading && _loadError == null && !isLandscape;
    final loop = ref.watch(loopProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;

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
        extendBodyBehindAppBar: glassLook,
        appBar: AppBar(
          backgroundColor: glassLook ? Colors.transparent : null,
          surfaceTintColor: glassLook ? Colors.transparent : null,
          centerTitle: glassLook,
          title: glassLook
              ? Text('AB 設定',
                  style: textTheme.labelMedium!
                      .copyWith(color: textTheme.bodySmall!.color))
              : Text(
                  'AB設定 - ${_item.title}',
                  style: textTheme.bodyLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          actions: [
            if (!_loading && _loadError == null) _buildWaveformAction(),
            if (!_loading && _loadError == null && _hasChanges)
              _buildSaveButton(),
            // 書き出し・クリアは使う頻度が低いのでメニューに
            if (glassLook)
              PopupMenuButton<String>(
                tooltip: 'その他',
                onSelected: (v) async {
                  if (v == 'export') _showExportDialog();
                  if (v == 'clear') {
                    final ok = await AppDialogs.confirm(context,
                        title: 'A・B をクリア',
                        message: 'この区間の A・B を未設定に戻しますか？',
                        confirmLabel: 'クリア',
                        destructive: true);
                    if (ok && mounted) ref.read(loopProvider.notifier).reset();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'export',
                    enabled: loop.hasBothPoints,
                    child: const ListTile(
                      leading: Icon(Icons.file_download_outlined),
                      title: Text('区間を書き出し'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'clear',
                    enabled: hasSource,
                    child: const ListTile(
                      leading: Icon(Icons.clear),
                      title: Text('A・B をクリア'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: _loading
              ? _buildLoadingView()
              : _loadError != null
                  ? _buildErrorView()
                  : _buildEditorView(bottomInset),
        ),
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

    // 縦画面: 再生画面と同じ骨組み（PlayerShell）。常に編集ブロックを出す
    final loop = ref.watch(loopProvider);
    final loopNotifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final duration = ref.watch(durationProvider).valueOrNull;

    // 選択中の区間の値をループ状態からリアルタイムに同期
    if (_regions.isNotEmpty) {
      _regions[_selectedRegionIdx] = _regions[_selectedRegionIdx].copyWith(
        pointAMs: () => loop.pointA?.inMilliseconds,
        pointBMs: () => loop.pointB?.inMilliseconds,
      );
    }
    final region = _regions[_selectedRegionIdx];
    final subParts = <String>[
      if (_item.bpm != null) 'BPM ${_item.bpm!.round()}',
      if (_item.musicalKey != null) _item.musicalKey!,
      if (duration != null && duration > Duration.zero)
        TimeUtils.formatShort(duration),
    ];

    return PlayerShell(
      item: _item,
      video: const VideoPlayerWidget(useAspectRatio: false),
      header: NowPlayingHeader(
        title: _item.title,
        subtitle: subParts.join('  ·  '),
        chip: HeaderChip(
          leading: const Icon(Icons.repeat,
              size: AppIconSizes.s, color: AppTheme.accentGreen),
          label: '区間',
          text: '${region.name}  ${RegionPanel.timeText(region)}',
          onTap: () => setState(() => _panelOpen = true),
        ),
      ),
      panel: _panelOpen
          ? RegionPanel(
              key: const ValueKey('regionPanel'),
              regions: _regions,
              selectedIndex: _selectedRegionIdx,
              onSelect: _selectRegion,
              onMenu: _showRegionMenu,
              onAdd: _regions.length < _maxRegions ? _addRegion : null,
            )
          : null,
      controller: SinglePlayerBar(
        seekbar: const LoopSeekbar(),
        regionsOpen: _panelOpen,
        loop: loop,
        onToggleLoop: loopNotifier.toggleEnabled,
        editing: true,
        editorMode: true,
        canEdit: false,
        onToggleRegions: () => setState(() => _panelOpen = !_panelOpen),
        onEdit: () {},
        onFinishEdit: () {},
        onMore: () {},
        onSetA: hasSource ? loopNotifier.setPointAToCurrentPosition : null,
        onSetB: hasSource ? loopNotifier.setPointBToCurrentPosition : null,
        editBlock: AbEditControls(
          loop: loop,
          step: loop.adjustStep,
          onStepChanged: loopNotifier.setStep,
          onSeek: (t) => ref.read(playerProvider).seek(t),
          onPointA: loopNotifier.setPointA,
          onPointB: loopNotifier.setPointB,
          onSwap: loopNotifier.swapPoints,
          onSetA: hasSource ? loopNotifier.setPointAToCurrentPosition : null,
          onSetB: hasSource ? loopNotifier.setPointBToCurrentPosition : null,
        ),
      ),
    );
  }


  Widget _buildLandscapeEditorView(double bottomInset) {

    return SafeArea(
      child: Row(
        children: [
          // === 左（60%）: 動画 + コントロール + 波形 ===
          Expanded(
            flex: 3,
            child: Column(
              children: [
                const Expanded(
                  child: VideoPlayerWidget(useAspectRatio: false),
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
          VerticalDivider(width: 1, color: Colors.grey.shade800),
          // === 右パネル（40%）: 縦並びレイアウト ===
          Expanded(
            flex: 2,
            child: _buildLandscapeEditorPanel(),
          ),
        ],
      ),
    );
  }

  /// 横画面右パネル: 縦並び（上: リージョンリスト、下: ABコントロール）
  Widget _buildLandscapeEditorPanel() {
    final loop = ref.watch(loopProvider);
    final loopNotifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    // リアルタイム同期
    if (_regions.isNotEmpty) {
      _regions[_selectedRegionIdx] = _regions[_selectedRegionIdx].copyWith(
        pointAMs: () => loop.pointA?.inMilliseconds,
        pointBMs: () => loop.pointB?.inMilliseconds,
      );
    }

    return Column(
      children: [
        // ループON/OFF + 書出し
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          child: Row(
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
                  label: Text(loop.enabled ? 'ON' : 'OFF'),
                  style: FilledButton.styleFrom(
                    backgroundColor: loop.enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    foregroundColor: loop.enabled ? Colors.black : Colors.grey,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                  ),
                ),
              ),
              if (loop.hasBothPoints) ...[
                const SizedBox(width: AppSpacing.md),
                Text(
                  '${((loop.pointB!.inMilliseconds - loop.pointA!.inMilliseconds).abs() / 1000).toStringAsFixed(1)}s',
                  style: textTheme.bodySmall!.copyWith(color: Colors.grey),
                ),
              ],
              const Spacer(),
              SizedBox(
                height: 26,
                child: TextButton.icon(
                  onPressed: loop.hasBothPoints ? _showExportDialog : null,
                  icon: const Icon(Icons.file_download, size: AppIconSizes.xs),
                  label: Text('書出し', style: textTheme.labelSmall),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppTheme.accentGreen,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // リージョンリスト
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            children: [
              for (var i = 0; i < _regions.length; i++) ...[
                _buildRegionTile(i),
                if (i < _regions.length - 1)
                  Divider(height: 1,
                      color: theme.dividerColor.withValues(alpha: 0.3)),
              ],
              const SizedBox(height: AppSpacing.sm),
              if (_regions.length < _maxRegions)
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
        const Divider(height: 1),
        // ABコントロール（縦画面と同じ部品の小さい版）
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: AbEditControls(
            loop: loop,
            step: loop.adjustStep,
            onStepChanged: loopNotifier.setStep,
            onSeek: (t) => ref.read(playerProvider).seek(t),
            onPointA: loopNotifier.setPointA,
            onPointB: loopNotifier.setPointB,
            onSwap: loopNotifier.swapPoints,
            onSetA: hasSource ? loopNotifier.setPointAToCurrentPosition : null,
            onSetB: hasSource ? loopNotifier.setPointBToCurrentPosition : null,
            compact: true,
          ),
        ),
      ],
    );
  }

  Widget _buildRegionTile(int index) {
    final region = _regions[index];
    final isSelected = index == _selectedRegionIdx;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    String timeText;
    if (region.hasA || region.hasB) {
      final aStr = TimeUtils.formatShortMs(region.pointAMs);
      final bStr = TimeUtils.formatShortMs(region.pointBMs);
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
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    region.name,
                    style: textTheme.labelMedium!.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? theme.colorScheme.primary : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    timeText,
                    style: textTheme.labelSmall!.copyWith(
                      color: (region.hasA || region.hasB)
                          ? null
                          : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
            // メニューは長押しでも開くが、入口が見えるように ⋮ も置く
            IconButton(
              icon: Icon(Icons.more_vert,
                  size: AppIconSizes.sm,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              tooltip: 'メニュー',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              onPressed: () => _showRegionMenu(index),
            ),
          ],
        ),
      ),
    );
  }

  void _showRegionMenu(int index) {
    if (index < 0 || index >= _regions.length) return;
    AppSheets.actions(
      context,
      title: _regions[index].name,
      actions: [
        SheetAction(
          icon: Icons.edit,
          label: '名前を変更',
          onTap: () => _renameRegion(index),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          subtitle: _regions.length > 1 ? null : '最後の 1 つは削除できません',
          destructive: true,
          enabled: _regions.length > 1,
          onTap: () => _deleteRegion(index),
        ),
      ],
    );
  }
}
