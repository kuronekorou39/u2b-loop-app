import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/storage/app_boxes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../models/loop_item.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../providers/glass_provider.dart';
import '../../widgets/empty_hint.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/item_thumbnail.dart';
import '../../widgets/reorder_handle.dart';
import '../../widgets/selection_mark.dart';
import '../../widgets/tag_chip.dart';
import '../../widgets/thumb_picker_sheet.dart';
import 'home_parts.dart';

/// タグ一覧の表示: リスト / グリッド大 / グリッド小（小は並べ替え向け。列数は幅で決まる）
enum TagViewMode {
  list(Icons.view_list, 'リスト'),
  grid2(Icons.grid_view, 'グリッド大'),
  grid4(Icons.apps, 'グリッド小');

  const TagViewMode(this.icon, this.label);

  final IconData icon;
  final String label;

  /// 保存した名前から戻す。無ければ旧設定（グリッドかどうか）から
  static TagViewMode fromName(String? name, {bool legacyGrid = false}) =>
      values.where((m) => m.name == name).firstOrNull ??
      (legacyGrid ? grid2 : list);
}

/// ホームの「タグ」タブ。タグの一覧（リスト / グリッド大 / グリッド小）と、名前・色の変更、削除、並べ替え。
/// 曲に付いたタグもこの並びで出る
///
/// タップは選択の切り替え（[onToggleSelect]）、長押ししたまま動かすと並べ替え
/// （リストは右の ≡ なら触れてすぐ動かせる）。長押しで選択には入らない。
/// 選んだタグでの検索・色・削除はホームの選択バー側（[selecting] は 1 件以上選んでいる間）
class TagManagerTab extends ConsumerWidget {
  const TagManagerTab({
    super.key,
    this.viewMode = TagViewMode.list,
    this.selecting = false,
    this.selectedIds = const {},
    this.onToggleSelect,
  });

  final TagViewMode viewMode;
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<Tag>? onToggleSelect;

  /// リストの行の右端の余白（つまみの列の当たり判定はここまで含める）
  static const _rowEndPadding = AppSpacing.xxl;

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
    return AppSheets.show<int>(
      context,
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
    // サムネを出すなら曲を返す（出さないなら常に null。出すがサムネが無い曲なら null）
    final showThumbs = ref.watch(tagThumbsProvider);
    LoopItem? thumbOf(Tag tag) => showThumbs ? tag.thumbItemOf(allItems) : null;

    void tap(Tag tag) => onToggleSelect?.call(tag);

    if (viewMode != TagViewMode.list) {
      return Column(
        children: [
          const _TagOrderHint(),
          Expanded(
            child: _TagGrid(
              tags: tags,
              small: viewMode == TagViewMode.grid4,
              showThumbs: showThumbs,
              thumbOf: thumbOf,
              selecting: selecting,
              selectedIds: selectedIds,
              countOf: countOf,
              onTap: tap,
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
          return SelectionDim(
            key: ValueKey(tag.id),
            selecting: selecting,
            selected: selected,
            // メニューは行の脇に出すので、行の context を取る
            // 行の長押しは並べ替え（選択はタップ）
            child: Builder(builder: (rowContext) => Stack(children: [
            ReorderableDelayedDragStartListener(
            index: i,
            child: ListTile(
            selected: selected,
            contentPadding: const EdgeInsetsDirectional.only(
                start: AppSpacing.xl, end: _rowEndPadding),
            // 色の丸は選択中も出したまま（選択の印は右端）
            leading: showThumbs
                ? _TagThumb(tag: tag, item: thumbOf(tag), size: 48)
                : _TagDot(tag: tag),
            title: Text(tag.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyLarge),
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
                        onPressed: () =>
                            _showMenu(rowContext, ref, tag, allItems),
                      ),
                      const ReorderHandleIcon(),
                    ],
                  ),
                ),
              ],
            ),
            onTap: () => tap(tag),
          )),
            // つまみの列（≡ から行の右端まで、行の高さいっぱい）はまるごと並べ替え。
            // ≡ の右や上下に、長押しで選択になる隙間を残さない
            if (!selecting)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: ReorderHandleIcon.width + _rowEndPadding,
                child: ReorderHandle.area(index: i),
              ),
          ])),
          );
        },
      ),
    );
  }

  void _showMenu(
      BuildContext context, WidgetRef ref, Tag tag, List<LoopItem> allItems) {
    final withThumb = [
      for (final item in allItems)
        if (item.tagIds.contains(tag.id) && item.thumbnailPath != null) item,
    ];
    AppSheets.actions(
      context,
      anchor: context,
      title: tag.name,
      actions: [
        if (ref.read(tagThumbsProvider) && withThumb.isNotEmpty)
          SheetAction(
            icon: Icons.image_outlined,
            label: 'サムネを選ぶ',
            onTap: () => ThumbPickerSheet.show(
              context,
              items: withThumb,
              currentId: tag.thumbItemOf(allItems)?.id,
              custom: tag.thumbItemId != null,
              resetLabel: '自動に戻す（よく再生する曲）',
              onPick: (id) => ref.read(tagsProvider.notifier).setThumb(tag.id, id),
            ),
          ),
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
                  Text('タップで選択、長押ししたまま動かして並べ替え',
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

/// タグのサムネ（正方形）。右下にタグの色の丸。サムネが無ければ薄い色の面にラベルのアイコン
class _TagThumb extends StatelessWidget {
  const _TagThumb({required this.tag, required this.item, required this.size});

  final Tag tag;
  final LoopItem? item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dot = size * 0.32;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: AppRadius.borderMd,
              child: item != null
                  ? ItemThumbnail(item: item!)
                  : ColoredBox(
                      color: tag.color.withValues(alpha: 0.25),
                      child: Icon(Icons.label, size: AppIconSizes.md, color: tag.color),
                    ),
            ),
          ),
          if (item != null)
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: tag.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
        ],
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
/// 動かさずに離しても何もしない（選択はタップ）
class _TagGrid extends StatefulWidget {
  const _TagGrid({
    required this.tags,
    required this.small,
    required this.showThumbs,
    required this.thumbOf,
    required this.selecting,
    required this.selectedIds,
    required this.countOf,
    required this.onTap,
    required this.onReorder,
  });

  final List<Tag> tags;

  /// 4 列（名前と曲数だけの小さなチップ）
  final bool small;

  /// サムネを出すか（設定）と、タグのサムネの曲（無ければ null）
  final bool showThumbs;
  final LoopItem? Function(Tag) thumbOf;
  final bool selecting;
  final Set<String> selectedIds;
  final int Function(Tag) countOf;
  final ValueChanged<Tag> onTap;
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
    if (oldIndex != newIndex) widget.onReorder(oldIndex, newIndex);
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

  /// 色つきのチップ（名前・曲数）。2 列も 4 列もタグの色を薄く敷いたガラス面。
  /// 2 列は左に色の丸（サムネを出すならサムネ）。4 列は左端の色の帯で、サムネがあれば
  /// 背景に暗くして敷く（文字は白）。
  /// 選択中は緑の枠とチェックを上に重ねるだけ（中身の大きさ・位置は変えない）
  Widget _chip(BuildContext context, Tag tag) {
    final textTheme = Theme.of(context).textTheme;
    final selected = widget.selectedIds.contains(tag.id);
    final small = widget.small;
    final radius = small ? 10.0 : 14.0;
    final thumb = widget.thumbOf(tag);
    // 4 列でサムネを背景に敷いたときは暗い膜の上なので白文字
    final onImage = small && thumb != null;
    final nameColor = onImage ? Colors.white : null;
    final countColor = onImage ? Colors.white70 : AppTheme.muted(context);

    final text = Column(
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
    );

    final Widget surface;
    if (small) {
      surface = GlassSurface(
        radius: radius,
        padding: EdgeInsets.zero,
        tint: tag.color.withValues(alpha: 0.12),
        onTap: () => widget.onTap(tag),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb != null) ...[
                ItemThumbnail(item: thumb),
                // 文字が読めるように暗くする（動画に重ねる一覧と同じく、読めることが優先）
                const ColoredBox(color: Color(0x99000000)),
              ],
              Row(
                children: [
                  Container(width: 4, color: tag.color),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                      child: Align(alignment: Alignment.centerLeft, child: text),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } else {
      surface = GlassSurface(
        radius: radius,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        tint: tag.color.withValues(alpha: 0.12),
        onTap: () => widget.onTap(tag),
        child: Row(
          children: [
            if (widget.showThumbs)
              _TagThumb(tag: tag, item: thumb, size: 40)
            else
              _TagDot(tag: tag),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: text),
          ],
        ),
      );
    }
    if (!widget.selecting) return surface;
    return SelectionDim(
      selecting: true,
      selected: selected,
      child: Stack(
      fit: StackFit.expand,
      children: [
        surface,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
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
                  : (onImage ? Colors.white70 : AppTheme.muted(context)),
            ),
          ),
        ),
      ],
    ),
    );
  }
}
