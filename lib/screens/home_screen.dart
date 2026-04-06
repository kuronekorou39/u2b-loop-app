import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../providers/theme_provider.dart';
import '../widgets/loop/loop_seekbar.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/video_player_widget.dart';
import '../widgets/url_input.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'U2B Loop',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () {
              ref.read(themeProvider.notifier).state = !isDark;
            },
            tooltip: isDark ? 'ライトテーマ' : 'ダークテーマ',
          ),
        ],
      ),
      body: const SingleChildScrollView(
        child: Column(
          children: [
            UrlInput(),
            VideoPlayerWidget(),
            PlayerControls(),
            LoopSeekbar(),
            SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}
