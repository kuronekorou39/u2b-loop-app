import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 一覧が空のときの案内（アイコン・見出し・補足）。ホームの各タブとプレイリスト詳細で共用。
/// 以前はアイコンと補足が 0.3 で読めないほど薄かった
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconSize = AppIconSizes.huge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: AppTheme.muted(context, alpha: 0.4)),
          const SizedBox(height: AppSpacing.lg),
          Text(title,
              style: TextStyle(color: AppTheme.muted(context, alpha: 0.75))),
          const SizedBox(height: AppSpacing.xs),
          Text(subtitle,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: AppTheme.muted(context, alpha: 0.6))),
        ],
      ),
    );
  }
}
