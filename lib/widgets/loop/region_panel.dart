import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../models/loop_region.dart';
import '../glass_panel.dart';
import '../player/player_shell.dart';

/// 開閉できる AB 区間の一覧（ガラス板）。再生画面（単体）と AB 編集画面で共用。
///
/// 見出しに件数と「追加」、▾ で閉じる。行は（[showAll] なら）「全体」と各区間。
/// 行のタップで切替、⋮ または長押しでリネーム・削除のメニュー。
class RegionPanel extends StatelessWidget {
  const RegionPanel({
    super.key,
    required this.regions,
    required this.selectedIndex,
    required this.onSelect,
    required this.onMenu,
    required this.onAdd,
    required this.onClose,
    this.showAll = false,
    this.onSelectAll,
  });

  final List<LoopRegion> regions;

  /// 選択中の区間。-1 は「全体」
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onMenu;

  /// null なら上限（追加できない）
  final VoidCallback? onAdd;
  final VoidCallback onClose;

  /// 先頭に「全体」の行を出す（再生画面）
  final bool showAll;
  final VoidCallback? onSelectAll;

  static String timeText(LoopRegion r) {
    if (r.pointAMs == null && r.pointBMs == null) return '未設定';
    final a = TimeUtils.formatShortMs(r.pointAMs);
    final b = TimeUtils.formatShortMs(r.pointBMs);
    if (r.pointAMs == null || r.pointBMs == null) return '$a - $b';
    final sec = (r.pointBMs! - r.pointAMs!).abs() / 1000;
    return '$a - $b (${sec.toStringAsFixed(1)}s)';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(
          PlayerShell.margin, 0, PlayerShell.margin, AppSpacing.lg),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.sm, 0),
            child: Row(
              children: [
                Text('AB 区間', style: textTheme.titleSmall),
                const SizedBox(width: AppSpacing.md),
                Text('${regions.length} 件', style: textTheme.labelSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: AppIconSizes.s),
                  label: Text(onAdd != null ? '追加' : '上限'),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: onClose,
                  tooltip: '一覧を閉じる',
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              children: [
                if (showAll)
                  _RegionRow(
                    name: '全体',
                    time: '',
                    isCurrent: selectedIndex == -1,
                    icon: Icons.all_inclusive,
                    onTap: onSelectAll ?? () {},
                  ),
                for (var i = 0; i < regions.length; i++)
                  _RegionRow(
                    name: regions[i].name,
                    time: timeText(regions[i]),
                    isCurrent: i == selectedIndex,
                    icon: Icons.repeat,
                    onTap: () => onSelect(i),
                    onMenu: () => onMenu(i),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionRow extends StatelessWidget {
  const _RegionRow({
    required this.name,
    required this.time,
    required this.isCurrent,
    required this.icon,
    required this.onTap,
    this.onMenu,
  });

  final String name;
  final String time;
  final bool isCurrent;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final dim = onSurface.withValues(alpha: 0.5);
    return InkWell(
      onTap: onTap,
      onLongPress: onMenu,
      child: Container(
        decoration: BoxDecoration(
          color: isCurrent ? AppTheme.accentGreen.withValues(alpha: 0.12) : null,
          border: Border(
            top: BorderSide(color: onSurface.withValues(alpha: 0.06)),
          ),
        ),
        padding: EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md + 2,
            onMenu == null ? AppSpacing.xl : AppSpacing.xs, AppSpacing.md + 2),
        child: Row(
          children: [
            Icon(icon,
                size: AppIconSizes.sm,
                color: isCurrent ? AppTheme.accentGreen : dim),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium!.copyWith(
                  fontSize: 14,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                  color: isCurrent ? AppTheme.accentGreen : null,
                ),
              ),
            ),
            Text(
              time,
              style: textTheme.labelSmall!
                  .copyWith(fontFeatures: const [FontFeature('tnum')]),
            ),
            if (onMenu != null)
              IconButton(
                icon: Icon(Icons.more_vert, size: AppIconSizes.sm, color: dim),
                onPressed: onMenu,
                tooltip: 'リネーム・削除',
                visualDensity: VisualDensity.compact,
              )
            else
              const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
