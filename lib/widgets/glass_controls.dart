import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'glass_panel.dart';

/// ガラス風の検索欄（ピル型。枠線なし、薄い面）
class GlassSearchField extends StatelessWidget {
  const GlassSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = '検索',
    this.onChanged,
    this.onClear,
    this.height = 40,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final ValueChanged<String>? onChanged;

  /// 入力があるときに出す × のタップ
  final VoidCallback? onClear;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        style: theme.textTheme.bodyMedium,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: theme.textTheme.bodyMedium!
              .copyWith(color: onSurface.withValues(alpha: 0.5)),
          prefixIcon: Icon(Icons.search,
              size: AppIconSizes.md, color: onSurface.withValues(alpha: 0.6)),
          suffixIcon: controller.text.isNotEmpty && onClear != null
              ? IconButton(
                  icon: const Icon(Icons.close, size: AppIconSizes.sm),
                  onPressed: onClear,
                  tooltip: 'クリア',
                )
              : null,
          isDense: true,
          filled: true,
          fillColor: onSurface.withValues(alpha: 0.10),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(999)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(999)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            borderSide: BorderSide(
                color: AppTheme.accentGreen.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }
}

/// ガラスのセグメント（タブ）。TabController に追従し、タップで animateTo。
/// 選択の印は緑の板 1 枚で、タブの間を横に滑る（スワイプ中は指に付いてくる）
class GlassSegmentedTabs extends StatelessWidget {
  const GlassSegmentedTabs({
    super.key,
    required this.controller,
    required this.labels,
  });

  final TabController controller;
  final List<String> labels;

  static const double _height = 36;

  /// タップで移るときの動き: 出だしが速く、終わりですっと止まる
  static const _tapDuration = Duration(milliseconds: 280);
  static const _tapCurve = Curves.easeOutCubic;

  /// 動いている間、板が横に伸びる割合（タブ 1 つの幅に対して。道のりの真ん中で最大）
  static const double _stretch = 0.22;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);
    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / labels.length;
          return AnimatedBuilder(
            animation: controller.animation ?? controller,
            builder: (context, _) {
              final current =
                  controller.animation?.value ?? controller.index.toDouble();
              final extra =
                  segmentWidth * _stretch * math.sin(math.pi * _progress(current));
              final width = segmentWidth + extra;
              final left = (current * segmentWidth - extra / 2)
                  .clamp(0.0, math.max(0.0, constraints.maxWidth - width))
                  .toDouble();
              return SizedBox(
                height: _height,
                child: Stack(
                  children: [
                    Positioned(
                      left: left,
                      width: width,
                      top: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        key: const ValueKey('segment-indicator'),
                        decoration: BoxDecoration(
                          color: AppTheme.accentGreen.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < labels.length; i++)
                          Expanded(
                            child: _Segment(
                              label: labels[i],
                              // 板が重なっている分だけ緑に
                              on: (1 - (current - i).abs()).clamp(0.0, 1.0),
                              style: textTheme.labelMedium!,
                              dim: dim,
                              onTap: () => controller.animateTo(i,
                                  duration: _tapDuration, curve: _tapCurve),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 今の移動の進み具合（0〜1）。タップで離れたタブへ飛ぶときは道のり全体で 1 回、
  /// スワイプ中は隣のタブまでを 1 回と数える
  double _progress(double current) {
    final from = controller.previousIndex;
    final to = controller.index;
    if (controller.indexIsChanging && from != to) {
      return ((current - from) / (to - from)).clamp(0.0, 1.0);
    }
    return current - current.floorToDouble();
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.on,
    required this.style,
    required this.dim,
    required this.onTap,
  });

  final String label;
  final double on;
  final TextStyle style;
  final Color dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: GlassSegmentedTabs._height,
        alignment: Alignment.center,
        child: Text(
          label,
          style: style.copyWith(
            color: Color.lerp(dim, AppTheme.accentGreen, on),
            fontWeight: on > 0.5 ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }
}

/// 主ボタン: 緑のグラデーション + 淡い発光（再生画面の再生ボタンと同じ）。
/// [label] が null ならアイコンだけの丸（FAB 用）
class GreenButton extends StatelessWidget {
  const GreenButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.label,
    this.size = 44,
    this.tooltip,
  });

  final IconData icon;
  final String? label;
  final VoidCallback? onPressed;

  /// 高さ（丸なら直径）
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    const color = AppTheme.accentGreen;
    final enabled = onPressed != null;
    final textTheme = Theme.of(context).textTheme;
    final shape = label == null
        ? const CircleBorder()
        : const StadiumBorder() as ShapeBorder;
    Widget button = Container(
      height: size,
      width: label == null ? size : null,
      decoration: ShapeDecoration(
        shape: shape,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: enabled
              ? const [Color(0xFF7CE8C4), color]
              : [color.withValues(alpha: 0.35), color.withValues(alpha: 0.3)],
        ),
        shadows: enabled
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onPressed,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : AppSpacing.xl),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: AppTheme.darkBackground, size: size * 0.5),
                if (label != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(label!,
                      style: textTheme.labelMedium!.copyWith(
                          color: AppTheme.darkBackground,
                          fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return button;
  }
}
