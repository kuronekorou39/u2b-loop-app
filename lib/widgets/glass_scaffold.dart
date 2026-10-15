import 'package:flutter/material.dart';

import '../providers/thumb_tone_provider.dart';

/// ガラス風の画面の土台: 透明な AppBar + グラデーションの背景 + 本文。
///
/// 背景は AppBar の裏まで通す（`extendBodyBehindAppBar`）ので、本文の上端は
/// AppBar の下端から始めること。その高さは **Scaffold の中の context** の
/// `MediaQuery.paddingOf(context).top` に入っている（State の context は Scaffold の
/// 外なので状態バーの分しか入らず、本文が AppBar の裏に隠れる）。
/// 上端の余白が要る画面は [bodyBuilder] を使い、渡された context から取ること。
/// [tone] を渡すと（詳細・プレイリスト詳細）サムネの色味、無ければ固定の青紫。
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    this.body,
    this.bodyBuilder,
    this.title,
    this.actions,
    this.leading,
    this.centerTitle = false,
    this.automaticallyImplyLeading = true,
    this.appBarBottom,
    this.toolbarHeight,
    this.tone,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset,
  }) : assert((body == null) != (bodyBuilder == null),
            'body か bodyBuilder のどちらか一方');

  /// 本文。上端の余白が要らない（自分で SafeArea する等）ときはこちら
  final Widget? body;

  /// 本文を Scaffold の中の context で組む。
  /// `MediaQuery.paddingOf(context).top` が AppBar の下端になる
  final WidgetBuilder? bodyBuilder;

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool centerTitle;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? appBarBottom;
  final double? toolbarHeight;
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
        toolbarHeight: toolbarHeight,
      ),
      body: Stack(
        children: [
          Positioned.fill(child: AppBackdrop(tone: tone)),
          body ?? Builder(builder: bodyBuilder!),
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
