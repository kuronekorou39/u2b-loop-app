import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/utils/url_utils.dart';
import '../models/loop_item.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import '../providers/loop_provider.dart';
import '../providers/player_provider.dart';
import '../services/thumbnail_service.dart';
import '../services/waveform_service.dart';
import '../widgets/loop/loop_controls.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/video_player_widget.dart';

enum _ScreenState { selectSource, loading, ready }

class EditorScreen extends ConsumerStatefulWidget {
  final LoopItem? item;

  const EditorScreen({super.key, this.item});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  late _ScreenState _state;
  bool _saving = false;
  bool _savedSuccessfully = false;
  String _loadingStatus = '';
  String _loadingTitle = '';
  double _loadingProgress = 0;
  DateTime _lastStepTime = DateTime.now();
  String? _cachedAudioPath;

  final _urlController = TextEditingController();
  late final TextEditingController _titleController;
  late final TextEditingController _memoController;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    _state = _isEditing ? _ScreenState.loading : _ScreenState.selectSource;
    _titleController = TextEditingController(text: widget.item?.title ?? '');
    _memoController = TextEditingController(text: widget.item?.memo ?? '');
    _loadingTitle = widget.item?.title ?? '';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(videoSourceProvider.notifier).state = null;
      ref.read(loopProvider.notifier).reset();
      ref.read(waveformDataProvider.notifier).state = null;
      ref.read(waveformLoadingProvider.notifier).state = false;
      ref.read(waveformErrorProvider.notifier).state = null;

      if (_isEditing) {
        _loadExisting();
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  void deactivate() {
    try {
      ref.read(playerProvider).stop();
    } catch (_) {}
    super.deactivate();
  }

  // --- Unsaved changes ---

  bool get _hasUnsavedChanges {
    if (_state != _ScreenState.ready || _savedSuccessfully) return false;

    final source = ref.read(videoSourceProvider);
    if (source == null) return false;

    if (!_isEditing) return true;

    final item = widget.item!;
    final loop = ref.read(loopProvider);
    final rate = ref.read(playerProvider).state.rate;

    if (_titleController.text.trim() != item.title) return true;
    if (_memoController.text.trim() != (item.memo ?? '')) return true;
    if (loop.pointA.inMilliseconds != item.pointAMs) return true;
    if (loop.pointB.inMilliseconds != item.pointBMs) return true;
    if (rate != item.speed) return true;

    return false;
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('変更を破棄しますか？'),
        content: const Text('保存していない変更があります。'),
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

  // --- Loading progress ---

  Future<void> _setProgress(double progress, String status) async {
    final elapsed = DateTime.now().difference(_lastStepTime).inMilliseconds;
    const minMs = 600;
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

  void _startLoading(String title) {
    _lastStepTime = DateTime.now();
    setState(() {
      _state = _ScreenState.loading;
      _loadingTitle = title;
      _loadingProgress = 0;
      _loadingStatus = '準備中...';
    });
  }

  Future<void> _finishLoading(VideoSource source) async {
    if (!mounted) return;

    // play:false だと libmpv が duration を解決しないことがあるので、
    // 一瞬再生→pause してメタデータ取得を強制する
    final player = ref.read(playerProvider);
    debugPrint('[FinishLoad] duration=${player.state.duration}');
    if (player.state.duration == Duration.zero) {
      await _setProgress(0.90, 'メタデータを取得中...');
      // ミュートして一瞬再生 → duration 解決 + ストリーム接続確立
      // （play:false のままだと libmpv が URL を掴んだまま MediaExtractor がアクセスできない）
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
      debugPrint('[FinishLoad] after play/pause: duration=${player.state.duration}');
    }

    if (!mounted) return;
    await _setProgress(1.0, '読み込み完了！');
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() => _state = _ScreenState.ready);

    // ローカルファイル or 事前DL成功時は波形を自動取得
    if (source.type == VideoSourceType.local || _cachedAudioPath != null) {
      _generateWaveform(source);
    }
  }

  // --- Load from URL (new) ---

  Future<void> _loadFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final videoId = UrlUtils.extractVideoId(url);
    if (videoId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無効なYouTube URLです')),
        );
      }
      return;
    }

    _startLoading('YouTube動画を読み込み中');

    try {
      await _setProgress(0.10, '動画情報を取得中...');
      final ytService = ref.read(youtubeServiceProvider);
      final video = await ytService.yt.videos.get(videoId);

      if (!mounted) return;
      await _setProgress(0.35, 'ストリーム情報を解析中...');
      final manifest =
          await ytService.yt.videos.streamsClient.getManifest(videoId);

      if (!mounted) return;
      await _setProgress(0.55, '最適な品質を選択中...');
      final muxed = manifest.muxed.sortByVideoQuality();
      String streamUrl;
      if (muxed.isNotEmpty) {
        streamUrl = muxed.last.url.toString();
      } else {
        final videoOnly = manifest.videoOnly.sortByVideoQuality();
        if (videoOnly.isEmpty) throw Exception('再生可能なストリームがありません');
        streamUrl = videoOnly.last.url.toString();
      }

      // プレーヤーを開く前に波形用音声をDL（CDN競合回避）
      if (!mounted) return;
      await _setProgress(0.60, '波形用音声を取得中...');
      await _tryDownloadAudio(manifest, ytService);

      final source = VideoSource(
        type: VideoSourceType.youtube,
        uri: streamUrl,
        title: video.title,
        videoId: videoId,
        thumbnailUrl: video.thumbnails.highResUrl,
      );

      if (!mounted) return;
      await _setProgress(0.80, 'プレーヤーを準備中...');
      final player = ref.read(playerProvider);
      await player.open(Media(source.uri), play: false);
      ref.read(videoSourceProvider.notifier).state = source;
      ref.read(loopProvider.notifier).reset();

      await _finishLoading(source);
    } catch (e) {
      if (mounted) {
        setState(() => _state = _ScreenState.selectSource);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込み失敗: $e')),
        );
      }
    }
  }

  // --- Load local file (new) ---

  Future<void> _loadLocalFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final path = file.path;
    if (path == null) return;

    _startLoading(file.name);

    try {
      await _setProgress(0.25, 'ファイルを読み込み中...');

      final source = VideoSource(
        type: VideoSourceType.local,
        uri: path,
        title: file.name,
      );

      if (!mounted) return;
      await _setProgress(0.65, 'プレーヤーを準備中...');
      final player = ref.read(playerProvider);
      await player.open(Media(path), play: false);
      ref.read(videoSourceProvider.notifier).state = source;
      ref.read(loopProvider.notifier).reset();

      await _finishLoading(source);
    } catch (e) {
      if (mounted) {
        setState(() => _state = _ScreenState.selectSource);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込み失敗: $e')),
        );
      }
    }
  }

  // --- Load existing (edit) ---

  Future<void> _loadExisting() async {
    final item = widget.item!;
    _startLoading(item.title);

    try {
      VideoSource source;

      if (item.sourceType == 'youtube' && item.videoId != null) {
        await _setProgress(0.10, '動画情報を取得中...');
        final ytService = ref.read(youtubeServiceProvider);
        final video = await ytService.yt.videos.get(item.videoId!);

        if (!mounted) return;
        await _setProgress(0.30, 'ストリーム情報を解析中...');
        final manifest =
            await ytService.yt.videos.streamsClient.getManifest(item.videoId!);

        if (!mounted) return;
        await _setProgress(0.50, '最適な品質を選択中...');
        final muxed = manifest.muxed.sortByVideoQuality();
        String streamUrl;
        if (muxed.isNotEmpty) {
          streamUrl = muxed.last.url.toString();
        } else {
          final videoOnly = manifest.videoOnly.sortByVideoQuality();
          if (videoOnly.isEmpty) throw Exception('再生可能なストリームがありません');
          streamUrl = videoOnly.last.url.toString();
        }

        // プレーヤーを開く前に波形用音声をDL（CDN競合回避）
        if (!mounted) return;
        await _setProgress(0.55, '波形用音声を取得中...');
        await _tryDownloadAudio(manifest, ytService);

        source = VideoSource(
          type: VideoSourceType.youtube,
          uri: streamUrl,
          title: video.title,
          videoId: item.videoId,
          thumbnailUrl: video.thumbnails.highResUrl,
        );
      } else {
        await _setProgress(0.30, 'ファイルを確認中...');
        source = VideoSource(
          type: VideoSourceType.local,
          uri: item.uri,
          title: item.title,
        );
      }

      if (!mounted) return;
      await _setProgress(0.70, 'プレーヤーを準備中...');
      final player = ref.read(playerProvider);
      await player.open(Media(source.uri), play: false);
      ref.read(videoSourceProvider.notifier).state = source;

      if (!mounted) return;
      await _setProgress(0.85, 'ループ設定を復元中...');
      if (item.pointAMs > 0 || item.pointBMs > 0) {
        ref
            .read(loopProvider.notifier)
            .setPointA(Duration(milliseconds: item.pointAMs));
        ref
            .read(loopProvider.notifier)
            .setPointB(Duration(milliseconds: item.pointBMs));
        ref.read(loopProvider.notifier).toggleEnabled();
      }

      if (item.speed != 1.0) {
        await player.setRate(item.speed);
      }

      await _finishLoading(source);
    } catch (e) {
      if (mounted) {
        setState(() => _state = _ScreenState.ready);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込み失敗: $e')),
        );
      }
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

      print('[Waveform] 結果: ${waveform == null ? "null" : "${waveform.length}サンプル"}');
      if (mounted) {
        if (waveform == null || waveform.isEmpty) {
          ref.read(waveformErrorProvider.notifier).state = '波形取得失敗';
        } else {
          ref.read(waveformDataProvider.notifier).state = waveform;
        }
      }
    } catch (e) {
      print('[Waveform] エラー: $e');
      if (mounted) {
        ref.read(waveformErrorProvider.notifier).state = '$e';
      }
    } finally {
      if (mounted) {
        ref.read(waveformLoadingProvider.notifier).state = false;
      }
    }
  }

  /// プレーヤーを開く前にmuxedストリームをDL（15秒タイムアウト、失敗しても続行）
  Future<void> _tryDownloadAudio(
      StreamManifest manifest, dynamic ytService) async {
    try {
      // muxed の最低品質を選択（audio-only は youtube_explode で DL できないため）
      final muxed = manifest.muxed.sortByVideoQuality();
      if (muxed.isEmpty) {
        print('[Waveform] muxedストリームなし');
        return;
      }
      final streamInfo = muxed.first; // 最低品質
      print('[Waveform] 事前DL: muxed ${streamInfo.qualityLabel} ${streamInfo.size}');

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
        print('[Waveform] 事前DLタイムアウト (${(bytes / 1024 / 1024).toStringAsFixed(1)}MB受信)');
      } finally {
        try { await sub.cancel().timeout(const Duration(seconds: 2)); } catch (_) {}
        try { await sink.flush().timeout(const Duration(seconds: 2)); } catch (_) {}
        try { await sink.close().timeout(const Duration(seconds: 2)); } catch (_) {}
      }

      if (bytes > 100000) {
        _cachedAudioPath = tempFile.path;
        print('[Waveform] 事前DL成功: ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB');
      } else {
        print('[Waveform] 事前DL不十分: ${bytes}bytes');
        try { await tempFile.delete(); } catch (_) {}
      }
    } catch (e) {
      print('[Waveform] 事前DLスキップ: $e');
    }
  }

  /// YouTube: キャッシュがあればそこから、なければ再DLを試みる
  Future<List<double>?> _generateYouTubeWaveform(
      VideoSource source, WaveformService service) async {
    // キャッシュがあればそれを使う
    if (_cachedAudioPath != null) {
      final path = _cachedAudioPath!;
      _cachedAudioPath = null;
      print('[Waveform] キャッシュから波形抽出: $path');
      try {
        return await service.generateFromUrl(path, 4000);
      } finally {
        try { await File(path).delete(); } catch (_) {}
      }
    }

    // キャッシュなし → 再DL試行（プレーヤーは止めない、15秒タイムアウト）
    print('[Waveform] キャッシュなし、再DL試行');
    final ytService = ref.read(youtubeServiceProvider);
    try {
      final manifest = await ytService.yt.videos.streamsClient
          .getManifest(source.videoId!)
          .timeout(const Duration(seconds: 10));
      await _tryDownloadAudio(manifest, ytService);
    } catch (e) {
      print('[Waveform] 再DL失敗: $e');
    }

    if (_cachedAudioPath != null) {
      final path = _cachedAudioPath!;
      _cachedAudioPath = null;
      print('[Waveform] 再DLキャッシュから波形抽出: $path');
      try {
        return await service.generateFromUrl(path, 4000);
      } finally {
        try { await File(path).delete(); } catch (_) {}
      }
    }
    return null;
  }

  // --- Save ---

  Future<void> _save() async {
    final source = ref.read(videoSourceProvider);
    if (source == null) return;

    setState(() => _saving = true);
    try {
      final loop = ref.read(loopProvider);
      final rate = ref.read(playerProvider).state.rate;
      final title = _titleController.text.trim().isNotEmpty
          ? _titleController.text.trim()
          : source.title;

      final id = widget.item?.id ??
          DateTime.now().millisecondsSinceEpoch.toString();

      String? thumbPath = widget.item?.thumbnailPath;
      if (source.thumbnailUrl != null) {
        final newPath =
            await ThumbnailService().save(id, source.thumbnailUrl);
        if (newPath != null) thumbPath = newPath;
      }

      if (_isEditing) {
        final item = widget.item!;
        item.title = title;
        item.uri = source.uri;
        item.thumbnailUrl = source.thumbnailUrl;
        item.thumbnailPath = thumbPath;
        item.pointAMs = loop.pointA.inMilliseconds;
        item.pointBMs = loop.pointB.inMilliseconds;
        item.speed = rate;
        item.memo = _memoController.text.trim().isEmpty
            ? null
            : _memoController.text.trim();
        ref.read(loopItemsProvider.notifier).update(item);
      } else {
        final item = LoopItem(
          id: id,
          title: title,
          uri: source.uri,
          sourceType: source.type == VideoSourceType.youtube
              ? 'youtube'
              : 'local',
          videoId: source.videoId,
          thumbnailUrl: source.thumbnailUrl,
          thumbnailPath: thumbPath,
          pointAMs: loop.pointA.inMilliseconds,
          pointBMs: loop.pointB.inMilliseconds,
          speed: rate,
          memo: _memoController.text.trim().isEmpty
              ? null
              : _memoController.text.trim(),
        );
        ref.read(loopItemsProvider.notifier).add(item);
      }

      _savedSuccessfully = true;
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

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    ref.listen(videoSourceProvider, (prev, next) {
      if (next != null && _titleController.text.isEmpty) {
        _titleController.text = next.title;
      }
    });

    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_state != _ScreenState.ready || !_hasUnsavedChanges) {
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
            _isEditing ? '編集' : '新規追加',
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            if (_state == _ScreenState.ready) ...[
              _buildWaveformAction(),
              _saving
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save, size: 18),
                      label: const Text('保存'),
                    ),
            ],
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          switchInCurve: Curves.easeIn,
          switchOutCurve: Curves.easeOut,
          child: _buildBody(bottomInset),
        ),
      ),
    );
  }

  Widget _buildBody(double bottomInset) {
    switch (_state) {
      case _ScreenState.selectSource:
        return _buildSourceSelector();
      case _ScreenState.loading:
        return _buildLoadingView();
      case _ScreenState.ready:
        return SingleChildScrollView(
          key: const ValueKey('editor'),
          child: Column(
            children: [
              const VideoPlayerWidget(),
              const PlayerControls(),
              const LoopSeekbar(),
              const LoopControls(),
              _buildMetadataCard(),
              SizedBox(height: 24 + bottomInset),
            ],
          ),
        );
    }
  }

  // --- Source selection (new items) ---

  Widget _buildSourceSelector() {
    return Padding(
      key: const ValueKey('source'),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 56,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '動画ソースを選択',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      hintText: 'YouTube URLを入力',
                      hintStyle: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.3),
                      ),
                      prefixIcon: const Icon(Icons.link, size: 20),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    maxLines: 3,
                    minLines: 1,
                    onSubmitted: (_) => _loadFromUrl(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.play_circle_fill),
                  iconSize: 36,
                  onPressed: _loadFromUrl,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'または',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.4),
                    ),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _loadLocalFile,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('ローカルファイルを選択'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Loading view ---

  Widget _buildLoadingView() {
    return Padding(
      key: const ValueKey('loading'),
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadingTitle,
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

  // --- Waveform action (header) ---

  Widget _buildWaveformAction() {
    final waveform = ref.watch(waveformDataProvider);
    final loading = ref.watch(waveformLoadingProvider);
    final error = ref.watch(waveformErrorProvider);

    // 取得中: スピナー表示
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
            Text(
              '波形取得中',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    // 失敗 or 未取得: 取得ボタン
    if (waveform == null && !loading) {
      final source = ref.read(videoSourceProvider);
      final tooltip = error != null
          ? '$error（タップで再取得）'
          : '波形を取得';
      return IconButton(
        icon: Icon(
          Icons.graphic_eq,
          size: 20,
          color: error != null ? Colors.orange : Colors.grey,
        ),
        tooltip: tooltip,
        onPressed: () {
          if (source != null) _generateWaveform(source);
        },
      );
    }

    return const SizedBox.shrink();
  }

  // --- Metadata card ---

  Widget _buildMetadataCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'タイトル',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _memoController,
              decoration: const InputDecoration(
                labelText: '備考',
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '練習メモなど',
              ),
              style: const TextStyle(fontSize: 14),
              maxLines: 2,
              minLines: 1,
            ),
          ],
        ),
      ),
    );
  }
}
