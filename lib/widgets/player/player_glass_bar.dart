import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../glass_panel.dart';
import 'player_shell.dart';

/// 再生画面の下部コントローラーの板（ガラス）。
///
/// 上から [seekbar] / [extra]（AB 編集ブロックなど、無ければ省く）/ [transport] の一列 /
/// [pills] の一列。中身はモードごとに渡す（プレイリスト: PlaylistBottomBar、単体: SinglePlayerBar）。
/// [compact] は中段のパネルを開いている間の低い形で、ピル行を省く。
/// 横画面では [PlayerDensity] で詰めた形（余白と再生ボタンを小さく）になり、
/// 横幅いっぱいに置くとき（[PlayerDensity.oneRow]）は再生操作とピルを 1 行にまとめる
/// （左のピル / 再生操作 / 右のピル。高さを抑えて動画とデッキの板の場所を空ける）。
class PlayerGlassBar extends StatelessWidget {
  const PlayerGlassBar({
    super.key,
    required this.seekbar,
    required this.transport,
    required this.compact,
    this.extra,
    this.pills,
  });

  final Widget seekbar;
  final Widget? extra;
  final List<Widget> transport;

  /// ピル行。Spacer を含めて並べたものを渡す。null なら行ごと省く
  final List<Widget>? pills;
  final bool compact;

  static const playSize = 76.0;
  static const playSizeCompact = 60.0;

  /// 横画面（詰めた形）の再生ボタン
  static const playSizeDense = 56.0;

  /// 再生ボタンの大きさ（低い形・詰めた形を見て）
  static double playSizeFor(BuildContext context, {required bool compact}) =>
      PlayerDensity.of(context)
          ? playSizeDense
          : compact
              ? playSizeCompact
              : playSize;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final dense = PlayerDensity.of(context);
    final oneRow = PlayerDensity.oneRowOf(context);
    // 詰めた形は上下の余白を 1 段ずつ小さく
    final top = dense
        ? AppSpacing.md
        : compact
            ? AppSpacing.lg
            : AppSpacing.xl + 2;
    final bottom = dense
        ? AppSpacing.lg
        : compact
            ? AppSpacing.xl
            : AppSpacing.xl + 4;
    final gap = dense
        ? AppSpacing.sm
        : compact
            ? AppSpacing.md
            : AppSpacing.xl;
    return GlassPanel(
      // 下はジェスチャーバー/ナビバーの分（bottomInset）に加えて余白をとる。
      // 画面の最下段は指が触れにくく、詰めると窮屈に見える
      margin: EdgeInsets.fromLTRB(PlayerShell.margin, 0, PlayerShell.margin,
          (dense ? AppSpacing.lg : AppSpacing.xl) + bottomInset),
      padding: EdgeInsets.fromLTRB(2, top, 2, bottom),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            seekbar,
            if (extra != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                child: extra,
              ),
            ],
            SizedBox(height: gap),
            if (oneRow)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                child: _oneRow(transport, compact ? null : pills),
              )
            else
              Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: dense ? AppSpacing.sm : AppSpacing.lg),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: transport,
                ),
              ),
            if (!oneRow && !compact && pills != null) ...[
              SizedBox(height: dense ? AppSpacing.md : AppSpacing.xl + 2),
              Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: dense ? AppSpacing.md : AppSpacing.xl),
                child: dense ? _densePills(pills!) : Row(children: pills!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// ピルを Spacer の左右に分ける
  static (List<Widget>, List<Widget>) _splitPills(List<Widget> pills) {
    final split = pills.indexWhere((p) => p is Spacer);
    final left = split < 0 ? pills : pills.sublist(0, split);
    final right = split < 0 ? const <Widget>[] : pills.sublist(split + 1);
    return (left, right);
  }

  /// 幅が足りなければ縮める、ピルのひとまとまり
  static Widget _pillGroup(List<Widget> ws, Alignment a) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: a,
        child: Row(mainAxisSize: MainAxisSize.min, children: ws),
      );

  /// 横幅いっぱいの 1 行: 左のピル / 再生操作（真ん中）/ 右のピル
  static Widget _oneRow(List<Widget> transport, List<Widget>? pills) {
    final (left, right) =
        pills == null ? (const <Widget>[], const <Widget>[]) : _splitPills(pills);
    return Row(
      children: [
        Expanded(child: _pillGroup(left, Alignment.centerLeft)),
        const SizedBox(width: AppSpacing.lg),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < transport.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.md),
              transport[i],
            ],
          ],
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(child: _pillGroup(right, Alignment.centerRight)),
      ],
    );
  }

  /// 詰めた形のピル行: Spacer の左右を両端に寄せ、幅が足りなければそれぞれを縮める
  /// （脇の狭い横画面。脇は IntrinsicHeight の中なので LayoutBuilder は使えない）
  static Widget _densePills(List<Widget> pills) {
    final (left, right) = _splitPills(pills);
    Widget part(List<Widget> ws, Alignment a) =>
        Flexible(child: _pillGroup(ws, a));
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        part(left, Alignment.centerLeft),
        if (right.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.md),
          part(right, Alignment.centerRight),
        ],
      ],
    );
  }
}

/// 横画面のコントローラーを詰めた形にする（[PlayerShell] の横レイアウトが付ける）
class PlayerDensity extends InheritedWidget {
  const PlayerDensity({
    super.key,
    required this.dense,
    this.oneRow = false,
    required super.child,
  });

  final bool dense;

  /// 横幅いっぱいに置く（再生操作とピルを 1 行に）
  final bool oneRow;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerDensity>()?.dense ?? false;

  static bool oneRowOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerDensity>()?.oneRow ??
      false;

  @override
  bool updateShouldNotify(PlayerDensity old) =>
      old.dense != dense || old.oneRow != oneRow;
}

/// シャッフル・リピート・ループのようなオン/オフのあるボタン。オンなら緑の丸を敷く
class ToggleIconButton extends StatelessWidget {
  const ToggleIconButton({
    super.key,
    required this.icon,
    required this.on,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final bool on;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final off = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return IconButton(
      icon: Icon(icon, size: AppIconSizes.ml),
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: on ? AppTheme.accentGreen : off,
        backgroundColor:
            on ? AppTheme.accentGreen.withValues(alpha: 0.18) : null,
        // 横画面の詰めた形は一回り小さく（脇が狭いと 5 つ並ばない）
        fixedSize: Size.square(PlayerDensity.of(context) ? 40 : 44),
      ),
    );
  }
}

/// 大きな再生ボタン。緑のグラデーションに淡い発光
class BigPlayButton extends StatelessWidget {
  const BigPlayButton({
    super.key,
    required this.playing,
    required this.enabled,
    required this.size,
    required this.onTap,
  });

  final bool playing;
  final bool enabled;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const color = AppTheme.accentGreen;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: enabled
              ? const [Color(0xFF7CE8C4), color]
              : [color.withValues(alpha: 0.35), color.withValues(alpha: 0.3)],
        ),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: Tooltip(
            message: playing ? '一時停止' : '再生',
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: size * 0.56,
              color: AppTheme.darkBackground,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「前の曲」「次の曲」「±N 秒」のような大きめのアイコンボタン
class TransportIconButton extends StatelessWidget {
  const TransportIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 44,
    this.onLongPress,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  /// 長押し（±N 秒の秒数変更など）。位置を渡す
  final void Function(Offset globalPosition)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final dense = PlayerDensity.of(context);
    final button = IconButton(
      icon: Icon(icon, size: dense ? size * 0.8 : size),
      // 詰めた形は周りの余白も小さく
      padding: dense ? const EdgeInsets.all(4) : null,
      onPressed: onPressed,
      tooltip: tooltip,
    );
    if (onLongPress == null || onPressed == null) return button;
    return GestureDetector(
      onLongPressStart: (d) => onLongPress!(d.globalPosition),
      child: button,
    );
  }
}

/// 編集中のピル「今を A」「今を B」（単体再生・プレイリスト・AB 設定で共用）
class SetPointPill extends StatelessWidget {
  const SetPointPill({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GlassPill(
      onTap: onTap,
      tooltip: '今の位置を $label にする',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.vertical_align_bottom,
              size: AppIconSizes.sm,
              color: onTap == null ? color.withValues(alpha: 0.4) : color),
          const SizedBox(width: AppSpacing.sm),
          Text('今を$label', style: textTheme.labelMedium),
        ],
      ),
    );
  }
}
