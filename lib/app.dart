import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
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
import 'providers/player_provider.dart';
import 'widgets/perf_overlay.dart';
import 'widgets/player/player_status_views.dart';
import 'widgets/share_import_dialog.dart';
import 'core/native_channels.dart';

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
        // PiP中はActivityの内容がそのまま縮小されて映るので、
        // どの画面にいてもルートで映像だけに差し替える。
        // 画面側で切り替えると、一覧画面などからPiPに入ったときに
        // その画面がそのままPiPに映ってしまう。
        // onPiPChanged が届く前でもウィンドウサイズで検知する（端末により遅れる）。
        final inPiP = ref.watch(pipModeProvider) ||
            MediaQuery.sizeOf(context).shortestSide < 250;
        if (inPiP) {
          // Navigator は Offstage で生かしたまま隠す。
          // ここで child を外すと全ルートが破棄され、PlayerScreen の dispose が
          // 走ってプレイヤーごと止まってしまう。
          // ミニプレイヤーバーは映像ウィジェットを持つので、この間は積まない
          // （media_kit の Video を同時に2つ出すとコントローラを取り合う）。
          return Stack(
            children: [
              Offstage(offstage: true, child: child!),
              const PiPVideoView(hideVideo: false, loading: false),
            ],
          );
        }
        // ミニプレイヤーは画面の下に浮かせる。出ている間は下の画面の MediaQuery の
        // 下インセットにその高さを足して、一覧の末尾や FAB が隠れないようにする
        final miniActive =
            ref.watch(miniPlayerProvider.select((s) => s.active));
        final mq = MediaQuery.of(context);
        final extra = miniActive ? MiniPlayerBar.reservedHeight : 0.0;
        return Stack(
          children: [
            MediaQuery(
              data: mq.copyWith(
                padding: mq.padding.copyWith(bottom: mq.padding.bottom + extra),
                viewPadding: mq.viewPadding
                    .copyWith(bottom: mq.viewPadding.bottom + extra),
              ),
              child: child!,
            ),
            if (showPerfOverlay) const PerfOverlay(),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MiniPlayerBar(),
            ),
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
  late final AppLinks _appLinks;
  StreamSubscription? _linkSub;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 起動時にautoPiPを無効化（安全策）
      NativeChannels.pip
          .invokeMethod('setAutoPiP', {'enabled': false}).catchError((_) {});
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
        NativeChannels.pip
            .invokeMethod('setAutoPiP', {'enabled': false}).catchError((_) {});
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
