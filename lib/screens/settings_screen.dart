import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/loop_item.dart';
import '../models/loop_region.dart';
import '../models/playlist.dart' as app;
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../providers/theme_provider.dart';
import '../services/update_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;

  // ─── Data stats ───

  int get _itemCount => Hive.box<LoopItem>('loop_items').length;
  int get _playlistCount => Hive.box<app.Playlist>('playlists').length;
  int get _tagCount => Hive.box<Tag>('tags').length;

  // ─── Export ───

  Map<String, dynamic> _itemToJson(LoopItem item) => {
        'id': item.id,
        'title': item.title,
        'uri': item.uri,
        'sourceType': item.sourceType,
        'videoId': item.videoId,
        'thumbnailUrl': item.thumbnailUrl,
        'pointAMs': item.pointAMs,
        'pointBMs': item.pointBMs,
        'speed': item.speed,
        'memo': item.memo,
        'createdAt': item.createdAt.toIso8601String(),
        'updatedAt': item.updatedAt.toIso8601String(),
        'fetchStatus': item.fetchStatus,
        'tagIds': item.tagIds,
        'youtubeUrl': item.youtubeUrl,
        'regions': item.regions.map((r) => r.toMap()).toList(),
      };

  Map<String, dynamic> _playlistToJson(app.Playlist pl) => {
        'id': pl.id,
        'name': pl.name,
        'itemIds': pl.itemIds,
        'createdAt': pl.createdAt.toIso8601String(),
        'regionSelections': pl.regionSelections,
        'disabledItemIds': pl.disabledItemIds.toList(),
      };

  Map<String, dynamic> _tagToJson(Tag tag) => {
        'id': tag.id,
        'name': tag.name,
      };

  Future<void> _exportData() async {
    setState(() => _busy = true);
    try {
      final items = Hive.box<LoopItem>('loop_items').values.toList();
      final playlists = Hive.box<app.Playlist>('playlists').values.toList();
      final tags = Hive.box<Tag>('tags').values.toList();

      final data = {
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'items': items.map(_itemToJson).toList(),
        'playlists': playlists.map(_playlistToJson).toList(),
        'tags': tags.map(_tagToJson).toList(),
      };

      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;

      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'バックアップを保存',
        fileName: 'u2b_loop_backup_$ts.json',
        bytes: bytes,
      );

      if (!mounted) return;
      if (result != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エクスポート完了')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エクスポート失敗: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── Import ───

  LoopItem _itemFromJson(Map<String, dynamic> j) => LoopItem(
        id: j['id'] as String,
        title: j['title'] as String,
        uri: j['uri'] as String,
        sourceType: j['sourceType'] as String,
        videoId: j['videoId'] as String?,
        thumbnailUrl: j['thumbnailUrl'] as String?,
        pointAMs: j['pointAMs'] as int? ?? 0,
        pointBMs: j['pointBMs'] as int? ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
        memo: j['memo'] as String?,
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
        fetchStatus: j['fetchStatus'] as String?,
        tagIds: (j['tagIds'] as List?)?.cast<String>() ?? [],
        youtubeUrl: j['youtubeUrl'] as String?,
        regions: (j['regions'] as List?)
                ?.map((m) =>
                    LoopRegion.fromMap((m as Map).cast<String, dynamic>()))
                .toList() ??
            [],
      );

  app.Playlist _playlistFromJson(Map<String, dynamic> j) {
    Map<String, List<String>>? regionSel;
    if (j['regionSelections'] != null) {
      final raw = (j['regionSelections'] as Map).cast<String, dynamic>();
      regionSel =
          raw.map((k, v) => MapEntry(k, (v as List).cast<String>()));
    }
    return app.Playlist(
      id: j['id'] as String,
      name: j['name'] as String,
      itemIds: (j['itemIds'] as List?)?.cast<String>() ?? [],
      createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
      regionSelections: regionSel,
      disabledItemIds:
          (j['disabledItemIds'] as List?)?.cast<String>().toSet(),
    );
  }

  Tag _tagFromJson(Map<String, dynamic> j) => Tag(
        id: j['id'] as String,
        name: j['name'] as String,
      );

  Future<void> _importData() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;

    final confirmed = await _showConfirmDialog(
      title: 'インポート',
      message: '既存のデータは上書きされます。続けますか？',
      confirmLabel: 'インポート',
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final jsonStr = utf8.decode(result.files.single.bytes!);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      final itemBox = Hive.box<LoopItem>('loop_items');
      final plBox = Hive.box<app.Playlist>('playlists');
      final tagBox = Hive.box<Tag>('tags');

      await itemBox.clear();
      await plBox.clear();
      await tagBox.clear();

      for (final j in (data['items'] as List? ?? [])) {
        final item = _itemFromJson(j as Map<String, dynamic>);
        await itemBox.put(item.id, item);
      }
      for (final j in (data['playlists'] as List? ?? [])) {
        final pl = _playlistFromJson(j as Map<String, dynamic>);
        await plBox.put(pl.id, pl);
      }
      for (final j in (data['tags'] as List? ?? [])) {
        final tag = _tagFromJson(j as Map<String, dynamic>);
        await tagBox.put(tag.id, tag);
      }

      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'インポート完了: ${data['items']?.length ?? 0}件のアイテム, '
              '${data['playlists']?.length ?? 0}件のプレイリスト, '
              '${data['tags']?.length ?? 0}件のタグ'),
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('インポート失敗: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── Clear ───

  Future<void> _clearData() async {
    final confirmed = await _showConfirmDialog(
      title: '全データ削除',
      message:
          '全てのアイテム・プレイリスト・タグが削除されます。\nこの操作は元に戻せません。',
      confirmLabel: '削除',
      isDestructive: true,
    );
    if (confirmed != true) return;

    final really = await _showConfirmDialog(
      title: '本当に削除しますか？',
      message:
          '$_itemCount件のアイテム、$_playlistCount件のプレイリスト、$_tagCount件のタグが完全に失われます。',
      confirmLabel: '完全に削除',
      isDestructive: true,
    );
    if (really != true) return;

    setState(() => _busy = true);
    try {
      await Hive.box<LoopItem>('loop_items').clear();
      await Hive.box<app.Playlist>('playlists').clear();
      await Hive.box<Tag>('tags').clear();

      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('全データを削除しました')),
      );
      setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── Helpers ───

  Future<bool?> _showConfirmDialog({
    required String title,
    required String message,
    required String confirmLabel,
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              confirmLabel,
              style: isDestructive
                  ? const TextStyle(color: Colors.red)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(themeProvider);

    return Scaffold(
      appBar:
          AppBar(title: const Text('設定', style: TextStyle(fontSize: 16))),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16,
                8 + MediaQuery.of(context).viewPadding.bottom),
            children: [
              // ── 外観 ──
              _sectionHeader('外観'),
              Card(
                child: SwitchListTile(
                  secondary:
                      Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                  title: const Text('ダークモード',
                      style: TextStyle(fontSize: 14)),
                  value: isDark,
                  onChanged: (v) =>
                      ref.read(themeProvider.notifier).state = v,
                ),
              ),

              const SizedBox(height: 16),

              // ── データ管理 ──
              _sectionHeader('データ管理'),
              Card(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          _statChip(
                              Icons.music_note, '$_itemCount', 'アイテム'),
                          const SizedBox(width: 12),
                          _statChip(Icons.queue_music,
                              '$_playlistCount', 'プレイリスト'),
                          const SizedBox(width: 12),
                          _statChip(
                              Icons.label_outline, '$_tagCount', 'タグ'),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.upload_file),
                      title: const Text('エクスポート',
                          style: TextStyle(fontSize: 14)),
                      subtitle: const Text('JSONファイルに書き出し',
                          style: TextStyle(fontSize: 12)),
                      onTap: _busy ? null : _exportData,
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.download),
                      title: const Text('インポート',
                          style: TextStyle(fontSize: 14)),
                      subtitle: const Text('JSONファイルから復元',
                          style: TextStyle(fontSize: 12)),
                      onTap: _busy ? null : _importData,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.delete_forever,
                          color: Colors.red),
                      title: const Text('データクリア',
                          style:
                              TextStyle(fontSize: 14, color: Colors.red)),
                      subtitle: const Text('全てのデータを削除',
                          style: TextStyle(fontSize: 12)),
                      onTap: _busy ? null : _clearData,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── アプリ情報 ──
              _sectionHeader('アプリ情報'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.system_update),
                      title: const Text('アップデートを確認',
                          style: TextStyle(fontSize: 14)),
                      onTap: () {
                        UpdateService.checkForUpdate(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('最新版を確認中...'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (ctx, snap) {
                        final version = snap.data?.version ?? '...';
                        return ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: const Text('バージョン',
                              style: TextStyle(fontSize: 14)),
                          subtitle: Text('v$version',
                              style: const TextStyle(fontSize: 12)),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
          if (_busy)
            Container(
              color: Colors.black38,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _statChip(IconData icon, String count, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icon, size: 16, color: Colors.grey),
            const SizedBox(height: 2),
            Text(count,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
