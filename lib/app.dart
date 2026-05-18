import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'providers/loading_animation_provider.dart';
import 'providers/mini_player_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/list_screen.dart';
import 'services/share_service.dart';
import 'services/update_service.dart';
import 'widgets/mini_player.dart';
import 'widgets/perf_overlay.dart';
import 'widgets/share_import_dialog.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

/// PlayerScreenが表示中かどうか（PiP制御用）
bool playerScreenActive = false;

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeProvider);
    final showPerfOverlay = ref.watch(perfOverlayProvider);
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'U2B Loop',
      theme: isDark ? AppTheme.dark : AppTheme.light,
      home: const _Home(),
      debugShowCheckedModeBanner: false,
      locale: const Locale('ja', 'JP'),
      supportedLocales: const [Locale('ja', 'JP')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        return Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  child!,
                  if (showPerfOverlay) const PerfOverlay(),
                ],
              ),
            ),
            const MiniPlayerBar(),
          ],
        );
      },
    );
  }
}

class _Home extends ConsumerStatefulWidget {
  const _Home();

  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> with WidgetsBindingObserver {
  static const _pipChannel = MethodChannel('com.u2bloop/pip');
  late final AppLinks _appLinks;
  StreamSubscription? _linkSub;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 起動時にautoPiPを無効化（安全策）
      try {
        _pipChannel.invokeMethod('setAutoPiP', {'enabled': false});
      } catch (_) {}
      UpdateService.checkForUpdate(context);
      _initDeepLinks();
    });
  }

  Future<void> _initDeepLinks() async {
    // アプリ起動時のURL
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) _handleUri(initialUri);
    } catch (_) {}

    // バックグラウンドからのURL
    _linkSub = _appLinks.uriLinkStream.listen(_handleUri);
  }

  void _handleUri(Uri uri) {
    final url = uri.toString();
    final data = ShareService.decode(url);
    if (data != null && mounted) {
      showShareImportDialog(context, ref, data);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      // バックグラウンド移行前: PlayerScreenもミニプレイヤーも非アクティブならPiP無効化
      if (playerScreenActive) return; // PlayerScreen表示中は触らない
      final miniState = ref.read(miniPlayerProvider);
      if (!miniState.active || miniState.item == null) {
        try {
          _pipChannel.invokeMethod('setAutoPiP', {'enabled': false});
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ListScreen();
}
