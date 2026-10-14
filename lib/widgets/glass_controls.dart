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

/// ガラスのセグメント（タブ）。TabController に追従し、タップで animateTo
class GlassSegmentedTabs extends StatelessWidget {
  const GlassSegmentedTabs({
    super.key,
    required this.controller,
    required this.labels,
  });

  final TabController controller;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);
    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: AnimatedBuilder(
        animation: controller.animation ?? controller,
        builder: (context, _) {
          final current = controller.animation?.value ?? controller.index.toDouble();
          return Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: _Segment(
                    label: labels[i],
                    // 隣へ動いている途中は両方を薄く
                    on: (1 - (current - i).abs()).clamp(0.0, 1.0),
                    style: textTheme.labelMedium!,
                    dim: dim,
                    onTap: () => controller.animateTo(i),
                  ),
                ),
            ],
          );
        },
      ),
    );
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
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.accentGreen.withValues(alpha: 0.18 * on),
          borderRadius: BorderRadius.circular(999),
        ),
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
