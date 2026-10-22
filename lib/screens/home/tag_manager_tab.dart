import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/storage/app_boxes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../widgets/empty_hint.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/selection_mark.dart';
import '../../widgets/tag_chip.dart';
import 'home_parts.dart';

/// タグ一覧の表示: リスト / 2列 / 4列（4 列は並べ替え向けに小さく）
enum TagViewMode {
  list(Icons.view_list, 'リスト'),
  grid2(Icons.grid_view, '2列'),
  grid4(Icons.apps, '4列');

  const TagViewMode(this.icon, this.label);

  final IconData icon;
  final String label;

  /// 保存した名前から戻す。無ければ旧設定（グリッドかどうか）から
  static TagViewMode fromName(String? name, {bool legacyGrid = false}) =>
      values.where((m) => m.name == name).firstOrNull ??
      (legacyGrid ? grid2 : list);
}

/// ホームの「タグ」タブ。タグの一覧（リスト / 2列 / 4列）と、名前・色の変更、削除、並べ替え。
/// 並べ替えはリストなら右の ≡ をドラッグ、グリッドなら長押ししたまま動かす
/// （動かさずに離すと長押し = 複数選択）。曲に付いたタグもこの並びで出る
///
/// 行をタップすると [onTagTap]（曲タブへ移ってそのタグで絞り込む）。
/// 複数選択中（[selecting]）はタップで選択の切替、操作はホームの選択バー側
class TagManagerTab extends ConsumerWidget {
  const TagManagerTab({
    super.key,
    required this.onTagTap,
    this.viewMode = TagViewMode.list,
    this.selecting = false,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onLongPress,
  });

  final ValueChanged<Tag> onTagTap;

  final TagViewMode viewMode;
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<Tag>? onToggleSelect;
  final ValueChanged<Tag>? onLongPress;

  /// FAB の「タグを作成」
  static Future<void> createTag(BuildContext context, WidgetRef ref) async {
    final name = await AppDialogs.prompt(context,
        title: 'タグを作成',
        hintText: 'タグ名',
        confirmLabel: '作成',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    await ref.read(tagsProvider.notifier).create(name);
  }

  /// まとめて削除（選択バーから）。使われている曲数を出して確認する。戻り値は消したか
  static Future<bool> deleteTags(
      BuildContext context, WidgetRef ref, List<Tag> tags) async {
    if (tags.isEmpty) return false;
    final items = ref.read(loopItemsProvider);
    final ids = tags.map((t) => t.id).toSet();
    final used = items.where((i) => i.tagIds.any(ids.contains)).length;
    final name = tags.length == 1 ? 'タグ「${tags.first.name}」' : 'タグ ${tags.length} 件';
    final ok = await AppDialogs.confirmDelete(context,
        title: 'タグを削除',
        message: used == 0
            ? '$nameを削除しますか？'
            : '$nameを削除しますか？\n$used 曲からこのタグが外れます（曲は残ります）');
    if (!ok) return false;
    ref.read(tagFilterProvider.notifier).update(
        (s) => Map<String, bool>.from(s)..removeWhere((k, _) => ids.contains(k)));
    for (final tag in tags) {
      await ref.read(tagsProvider.notifier).delete(tag.id);
      await ref.read(loopItemsProvider.notifier).removeTagFromAll(tag.id);
    }
    return true;
  }

  /// 色を選ぶシート。[current] は選択中の色番号（複数のときは null）
  static Future<int?> pickColor(BuildContext context,
      {required String title, int? current}) {
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xl),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.lg,
                children: [
                  for (var i = 0; i < tagPresetColors.length; i++)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(ctx, i),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: tagPresetColors[i],
                          shape: BoxShape.circle,
                          border: current == i
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                        ),
                        child: i == 0
                            ? Center(
                                child: Text('D',
                                    style: Theme.of(ctx)
                                        .textTheme
                                        .bodyLarge
                                        ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white)))
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// まとめて色を変える（選択バーから）
  static Future<void> recolorTags(
      BuildContext context, WidgetRef ref, List<Tag> tags) async {
    if (tags.isEmpty) return;
    final same = tags.every((t) => t.colorIndex == tags.first.colorIndex);
    final picked = await pickColor(context,
        title: tags.length == 1 ? '「${tags.first.name}」の色' : '${tags.length} 件の色',
        current: same ? tags.first.colorIndex : null);
    if (picked == null) return;
    for (final tag in tags) {
      ref.read(tagsProvider.notifier).setColor(tag.id, picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    final allItems = ref.watch(loopItemsProvider);

    if (tags.isEmpty) {
      return const EmptyHint(
          icon: Icons.label_outline, title: 'タグがありません', subtitle: '＋ ボタンで作成');
    }

    int countOf(Tag tag) =>
        allItems.where((item) => item.tagIds.contains(tag.id)).length;

    void tap(Tag tag) {
      if (selecting) {
        onToggleSelect?.call(tag);
      } else {
        onTagTap(tag);
      }
    }

    if (viewMode != TagViewMode.list) {
      return Column(
        children: [
          const _TagOrderHint(),
          Expanded(
            child: _TagGrid(
              tags: tags,
              small: viewMode == TagViewMode.grid4,
              selecting: selecting,
              selectedIds: selectedIds,
              countOf: countOf,
              onTap: tap,
              onLongPress: (tag) => onLongPress?.call(tag),
              onReorder: ref.read(tagsProvider.notifier).reorder,
            ),
          ),
        ],
      );
    }

    final textTheme = Theme.of(context).textTheme;
    return HomeListSurface(
      child: ReorderableListView.builder(
        padding: HomeListSurface.listPadding,
        header: const _TagOrderHint(),
        buildDefaultDragHandles: false,
        itemCount: tags.length,
        onReorderItem: ref.read(tagsProvider.notifier).reorder,
        itemBuilder: (context, i) {
          final tag = tags[i];
          final selected = selectedIds.contains(tag.id);
          return ListTile(
            key: ValueKey(tag.id),
            selected: selected,
            // 色の丸は選択中も出したまま（選択の印は右端）
            leading: _TagDot(tag: tag),
            title: Text(tag.name, style: textTheme.bodyLarge),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${countOf(tag)} 曲', style: textTheme.bodySmall),
                // 選択の印はメニューと ≡ の場所に（隠すだけで場所は残す）
                SelectionTrailing(
                  selecting: selecting,
                  selected: selected,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: AppIconSizes.md),
                        tooltip: 'メニュー',
                        onPressed: () => _showMenu(context, ref, tag),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        enabled: !selecting,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: Icon(Icons.drag_handle,
                              size: AppIconSizes.md,
                              color: AppTheme.muted(context)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            onTap: () => tap(tag),
            onLongPress: () => onLongPress?.call(tag),
          );
        },
      ),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref, Tag tag) {
    AppSheets.actions(
      context,
      title: tag.name,
      actions: [
        SheetAction(
          icon: Icons.edit,
          label: '名前を変更',
          onTap: () => _rename(context, ref, tag),
        ),
        SheetAction(
          icon: Icons.palette_outlined,
          label: '色を変更',
          onTap: () => recolorTags(context, ref, [tag]),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => deleteTags(context, ref, [tag]),
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Tag tag) async {
    final name = await AppDialogs.prompt(context,
        title: 'タグ名変更',
        initialValue: tag.name,
        hintText: 'タグ名',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    ref.read(tagsProvider.notifier).rename(tag.id, name);
  }
}

/// タグの並びの使い方を一度だけ見せるカード（閉じたら出さない）。
/// 見本のタグは実際には作らない（データを汚さない）
class _TagOrderHint extends StatefulWidget {
  const _TagOrderHint();

  @override
  State<_TagOrderHint> createState() => _TagOrderHintState();
}

class _TagOrderHintState extends State<_TagOrderHint> {
  bool _seen = AppBoxes.settings
      .get(SettingsKeys.tagOrderHintSeen, defaultValue: false) as bool;

  static final _examples = [
    Tag(id: '_ex_genre', name: 'ジャンル', colorIndex: 4),
    Tag(id: '_ex_artist', name: 'アーティスト', colorIndex: 5),
    Tag(id: '_ex_album', name: 'アルバム', colorIndex: 2),
  ];

  @override
  Widget build(BuildContext context) {
    if (_seen) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      child: GlassSurface(
        radius: 14,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.xs, AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('上から並べた順に、曲のタグも並びます',
                      style: textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (i, t) in _examples.indexed) ...[
                        if (i > 0)
                          Icon(Icons.chevron_right,
                              size: AppIconSizes.s,
                              color: AppTheme.muted(context)),
                        TagChip(tag: t),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text('リストは右の ≡、グリッドは長押ししたまま動かして並べ替え',
                      style: textTheme.labelSmall),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: AppIconSizes.md),
              tooltip: '閉じる',
              onPressed: () {
                setState(() => _seen = true);
                AppBoxes.settings.put(SettingsKeys.tagOrderHintSeen, true);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// タグの色の丸（中にラベルのアイコン）
class _TagDot extends StatelessWidget {
  const _TagDot({required this.tag});

  final Tag tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppIconSizes.lg,
      height: AppIconSizes.lg,
      decoration: BoxDecoration(
        color: tag.color.withValues(alpha: 0.25),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.label, size: AppIconSizes.xs, color: tag.color),
    );
  }
}

/// タグのグリッド。長押ししたまま動かすと並べ替え（動かしている間は並びを先に見せる）。
/// 動かさずに離したら [onLongPress]（複数選択）
class _TagGrid extends StatefulWidget {
  const _TagGrid({
    required this.tags,
    required this.small,
    required this.selecting,
    required this.selectedIds,
    required this.countOf,
    required this.onTap,
    required this.onLongPress,
    required this.onReorder,
  });

  final List<Tag> tags;

  /// 4 列（名前と曲数だけの小さなチップ）
  final bool small;
  final bool selecting;
  final Set<String> selectedIds;
  final int Function(Tag) countOf;
  final ValueChanged<Tag> onTap;
  final ValueChanged<Tag> onLongPress;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  State<_TagGrid> createState() => _TagGridState();
}

class _TagGridState extends State<_TagGrid> {
  /// ドラッグ中の並び（離すまで保存しない）
  List<Tag>? _preview;

  void _moveOver(String draggedId, Tag target) {
    final preview = _preview;
    if (preview == null || draggedId == target.id) return;
    final from = preview.indexWhere((t) => t.id == draggedId);
    final to = preview.indexWhere((t) => t.id == target.id);
    if (from < 0 || to < 0) return;
    setState(() => preview.insert(to, preview.removeAt(from)));
  }

  void _endDrag(Tag tag) {
    final preview = _preview;
    setState(() => _preview = null);
    if (preview == null) return;
    final oldIndex = widget.tags.indexWhere((t) => t.id == tag.id);
    final newIndex = preview.indexWhere((t) => t.id == tag.id);
    if (oldIndex < 0 || newIndex < 0) return;
    if (oldIndex == newIndex) {
      widget.onLongPress(tag);
    } else {
      widget.onReorder(oldIndex, newIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = _preview ?? widget.tags;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    final small = widget.small;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 80 + bottomPad),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: small ? 100 : 200,
        mainAxisExtent: small ? 44 : 56,
        crossAxisSpacing: small ? AppSpacing.sm : AppSpacing.md,
        mainAxisSpacing: small ? AppSpacing.sm : AppSpacing.md,
      ),
      itemCount: tags.length,
      // 並びが変わっても同じタグの部品を使い続ける（動かしているタグが作り直されると
      // ドラッグの終わりが届かない）
      findChildIndexCallback: (key) {
        final i = tags.indexWhere((t) => ValueKey(t.id) == key);
        return i < 0 ? null : i;
      },
      itemBuilder: (context, i) {
        final tag = tags[i];
        return DragTarget<String>(
          key: ValueKey(tag.id),
          onWillAcceptWithDetails: (d) {
            _moveOver(d.data, tag);
            return true;
          },
          builder: (context, _, _) => LayoutBuilder(
            builder: (context, constraints) {
              final chip = _chip(context, tag);
              return LongPressDraggable<String>(
                data: tag.id,
                onDragStarted: () =>
                    setState(() => _preview = List.of(widget.tags)),
                onDragEnd: (_) => _endDrag(tag),
                feedback: Material(
                  type: MaterialType.transparency,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Transform.scale(scale: 1.06, child: chip),
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.3, child: chip),
                child: chip,
              );
            },
          ),
        );
      },
    );
  }

  /// 色つきのチップ（名前・曲数）。2 列は色の丸 + 薄い色、4 列はタグの色で塗る。
  /// 選択中は緑の枠とチェックを上に重ねるだけ（中身の大きさ・位置は変えない）
  Widget _chip(BuildContext context, Tag tag) {
    final textTheme = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selected = widget.selectedIds.contains(tag.id);
    final small = widget.small;
    // 4 列: タグの色の面に、明るさで白/黒の文字
    final fill = tag.color.withValues(alpha: dark ? 0.55 : 0.45);
    final onFill = Color.alphaBlend(
                    fill, dark ? AppTheme.darkBackground : Colors.white)
                .computeLuminance() >
            0.45
        ? Colors.black87
        : Colors.white;
    final nameColor = small ? onFill : null;
    final countColor =
        small ? onFill.withValues(alpha: 0.75) : AppTheme.muted(context);

    final surface = GlassSurface(
      radius: small ? 10 : 14,
      padding: EdgeInsets.symmetric(
          horizontal: small ? AppSpacing.sm : AppSpacing.md,
          vertical: small ? AppSpacing.xs : AppSpacing.sm),
      tint: small ? fill : tag.color.withValues(alpha: 0.12),
      onTap: () => widget.onTap(tag),
      child: Row(
        children: [
          if (!small) ...[
            _TagDot(tag: tag),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tag.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (small ? textTheme.labelSmall : textTheme.labelMedium)
                        ?.copyWith(fontWeight: FontWeight.w600, color: nameColor)),
                Text('${widget.countOf(tag)} 曲',
                    maxLines: 1,
                    style: textTheme.labelSmall?.copyWith(color: countColor)),
              ],
            ),
          ),
        ],
      ),
    );
    if (!widget.selecting) return surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        surface,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(small ? 10 : 14),
                color: selected
                    ? AppTheme.accentGreen.withValues(alpha: 0.18)
                    : null,
                border: selected
                    ? Border.all(color: AppTheme.accentGreen, width: 2)
                    : null,
              ),
            ),
          ),
        ),
        Positioned(
          top: 3,
          right: 3,
          child: IgnorePointer(
            child: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: AppIconSizes.s,
              color: selected
                  ? AppTheme.accentGreen
                  : (small ? countColor : AppTheme.muted(context)),
            ),
          ),
        ),
      ],
    );
  }
}
