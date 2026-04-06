import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/url_utils.dart';
import '../models/video_source.dart';
import '../providers/loop_provider.dart';
import '../providers/player_provider.dart';
import '../services/waveform_service.dart';

class UrlInput extends ConsumerStatefulWidget {
  final bool initialCollapsed;

  const UrlInput({super.key, this.initialCollapsed = false});

  @override
  ConsumerState<UrlInput> createState() => _UrlInputState();
}

class _UrlInputState extends ConsumerState<UrlInput> {
  final _controller = TextEditingController();
  bool _loading = false;
  late bool _expanded = !widget.initialCollapsed;
  int _waveformGeneration = 0;

  Future<void> _loadYoutube() async {
    final url = _controller.text.trim();
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

    setState(() => _loading = true);
    try {
      final source =
          await ref.read(youtubeServiceProvider).getVideoSource(videoId);
      final player = ref.read(playerProvider);
      await player.open(Media(source.uri));
      ref.read(videoSourceProvider.notifier).state = source;
      ref.read(loopProvider.notifier).reset();
      _generateWaveform(source);
      if (mounted) setState(() => _expanded = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込み失敗: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickLocalFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final path = file.path;
    if (path == null) return;

    final player = ref.read(playerProvider);
    await player.open(Media(path));
    final source = VideoSource(
      type: VideoSourceType.local,
      uri: path,
      title: file.name,
    );
    ref.read(videoSourceProvider.notifier).state = source;
    ref.read(loopProvider.notifier).reset();
    _generateWaveform(source);
    if (mounted) setState(() => _expanded = false);
  }

  Future<void> _generateWaveform(VideoSource source) async {
    final generation = ++_waveformGeneration;
    ref.read(waveformDataProvider.notifier).state = null;
    ref.read(waveformLoadingProvider.notifier).state = true;

    try {
      final service = WaveformService();
      final waveform = await service.generateFromUrl(source.uri, 4000);

      if (mounted && generation == _waveformGeneration) {
        ref.read(waveformDataProvider.notifier).state = waveform;
      }
    } catch (_) {
    } finally {
      if (mounted && generation == _waveformGeneration) {
        ref.read(waveformLoadingProvider.notifier).state = false;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(videoSourceProvider);

    // Collapsed: show title bar
    if (!_expanded && source != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: GestureDetector(
          onTap: () => setState(() => _expanded = true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: AppRadius.borderMd,
            ),
            child: Row(
              children: [
                Icon(
                  source.type == VideoSourceType.youtube
                      ? Icons.play_circle_outline
                      : Icons.video_file_outlined,
                  size: AppIconSizes.sm,
                  color: Colors.grey,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    source.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.unfold_more, size: AppIconSizes.sm, color: Colors.grey),
              ],
            ),
          ),
        ),
      );
    }

    // Expanded: full input UI
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          // Collapse button (when source is loaded)
          if (source != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: GestureDetector(
                onTap: () => setState(() => _expanded = false),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: AppRadius.borderMd,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        source.type == VideoSourceType.youtube
                            ? Icons.play_circle_outline
                            : Icons.video_file_outlined,
                        size: AppIconSizes.s,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          source.title,
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.unfold_less,
                          size: AppIconSizes.sm, color: Colors.grey),
                    ],
                  ),
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'YouTube URLを入力',
                    prefixIcon: Icon(Icons.link, size: AppIconSizes.md),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _loadYoutube(),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              _loading
                  ? const SizedBox(
                      width: 40,
                      height: 40,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.play_circle_fill),
                      iconSize: 36,
                      onPressed: _loadYoutube,
                      color: Theme.of(context).colorScheme.primary,
                    ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _pickLocalFile,
              icon: const Icon(Icons.folder_open, size: AppIconSizes.sm),
              label: const Text('ローカルファイルを選択'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
