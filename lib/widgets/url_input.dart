import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../core/utils/url_utils.dart';
import '../models/video_source.dart';
import '../providers/loop_provider.dart';
import '../providers/player_provider.dart';

class UrlInput extends ConsumerStatefulWidget {
  const UrlInput({super.key});

  @override
  ConsumerState<UrlInput> createState() => _UrlInputState();
}

class _UrlInputState extends ConsumerState<UrlInput> {
  final _controller = TextEditingController();
  bool _loading = false;

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
    ref.read(videoSourceProvider.notifier).state = VideoSource(
      type: VideoSourceType.local,
      uri: path,
      title: file.name,
    );
    ref.read(loopProvider.notifier).reset();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'YouTube URLを入力',
                    prefixIcon: Icon(Icons.link, size: 20),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _loadYoutube(),
                ),
              ),
              const SizedBox(width: 8),
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
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _pickLocalFile,
              icon: const Icon(Icons.folder_open, size: 18),
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
