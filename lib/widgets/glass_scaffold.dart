import 'package:flutter/material.dart';

import '../providers/thumb_tone_provider.dart';

/// ガラス風の画面の土台: 透明な AppBar + グラデーションの背景 + 本文。
///
/// 背景は AppBar の裏まで通す（`extendBodyBehindAppBar`）ので、本文の上端は
/// `MediaQuery.paddingOf(context).top`（AppBar の下端）から始めること。
/// [tone] を渡すと（詳細・プレイリスト詳細）サムネの色味、無ければ固定の青紫。
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    required this.body,
    this.title,
    this.actions,
    this.leading,
    this.centerTitle = false,
    this.automaticallyImplyLeading = true,
    this.appBarBottom,
    this.tone,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset,
  });

  final Widget body;
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool centerTitle;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? appBarBottom;
  final ThumbTone? tone;
  final Widget? floatingActionButton;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: title,
        actions: actions,
        leading: leading,
        centerTitle: centerTitle,
        automaticallyImplyLeading: automaticallyImplyLeading,
        bottom: appBarBottom,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: AppBackdrop(tone: tone)),
          body,
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}

/// 画面の背景。上が少し明るい色のグラデーションで、下へ行くほど地色に沈む。
/// [tone] が変わるとなめらかに移る（再生画面と同じ）
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, this.tone});

  final ThumbTone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = (tone ?? ThumbTone.fallback).gradient(
      theme.scaffoldBackgroundColor,
      dark: theme.brightness == Brightness.dark,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    );
  }
}
