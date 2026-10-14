import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../providers/data_provider.dart';
import '../../services/backup_service.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「バックアップ」: 書き出し / 復元
class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() =>
      _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  bool _busy = false;

  void _toast(SnackBar bar) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
  }

  Future<void> _exportData() async {
    setState(() => _busy = true);
    try {
      final json = BackupService.encode(
        items: AppBoxes.loopItems.values.toList(),
        playlists: AppBoxes.playlists.values.toList(),
        tags: AppBoxes.tags.values.toList(),
      );
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'バックアップを保存',
        fileName: BackupService.fileName(),
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      if (saved != null) _toast(AppSnackBar.success('書き出しました'));
    } catch (e) {
      _toast(AppSnackBar.error('書き出しに失敗しました: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importData() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final bytes = picked?.files.single.bytes;
    if (bytes == null) return;

    // 先に全件読み込んで検証する。ここで失敗しても今のデータには触れない
    final BackupData data;
    try {
      data = BackupService.decode(utf8.decode(bytes));
    } on FormatException catch (e) {
      _toast(AppSnackBar.error(e.message));
      return;
    } catch (e) {
      _toast(AppSnackBar.error('読み込みに失敗しました: $e'));
      return;
    }

    if (!mounted) return;
    final confirmed = await AppDialogs.confirm(
      context,
      title: 'バックアップから復元',
      message: 'アイテム ${data.items.length}件・プレイリスト ${data.playlists.length}件・'
          'タグ ${data.tags.length}件で、今のデータをすべて置き換えます。',
      confirmLabel: '置き換える',
      destructive: true,
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await BackupService.restore(data);
      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);
      _toast(AppSnackBar.success('復元しました'));
      if (mounted) setState(() {});
      // サムネイル画像は端末固有なのでバックアップに含めていない。取り直す
      _repairThumbnailsWithProgress();
    } catch (e) {
      _toast(AppSnackBar.error('復元に失敗しました: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatEta(Duration d) {
    if (d.inHours > 0) return '約${d.inHours}時間${d.inMinutes % 60}分';
    if (d.inMinutes > 0) return '約${d.inMinutes}分';
    return '1分未満';
  }

  void _repairThumbnailsWithProgress() {
    final textTheme = Theme.of(context).textTheme;
    final doneNotifier = ValueNotifier<int>(0);
    final totalNotifier = ValueNotifier<int>(0);
    final etaNotifier = ValueNotifier<String>('');
    final startTime = DateTime.now();

    showDialog(
      context: context,
      barrierDismissible: false,
      // 戻るボタンで閉じられると、完了時のpopが設定画面自体を閉じてしまう
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: totalNotifier,
            builder: (_, total, _) => ValueListenableBuilder<int>(
              valueListenable: doneNotifier,
              builder: (_, done, _) => ValueListenableBuilder<String>(
                valueListenable: etaNotifier,
                builder: (_, eta, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: AppSpacing.xl),
                        Expanded(
                          child: Text('サムネイルを復元中...',
                              style: textTheme.bodyLarge),
                        ),
                      ],
                    ),
                    if (total > 0) ...[
                      const SizedBox(height: AppSpacing.lg),
                      LinearProgressIndicator(value: done / total),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('$done / $total', style: textTheme.bodySmall),
                          if (eta.isNotEmpty)
                            Text('残り $eta', style: textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    ref.read(loopItemsProvider.notifier).repairThumbnails(
      onProgress: (done, total) {
        doneNotifier.value = done;
        totalNotifier.value = total;
        if (done >= 3) {
          final elapsed = DateTime.now().difference(startTime);
          final perItem = elapsed.inMilliseconds / done;
          etaNotifier.value = _formatEta(
              Duration(milliseconds: (perItem * (total - done)).round()));
        }
      },
    ).whenComplete(() {
      // 失敗時も必ずダイアログを閉じる
      doneNotifier.dispose();
      totalNotifier.dispose();
      etaNotifier.dispose();
      if (mounted) Navigator.pop(context);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SettingsPage(
          title: 'バックアップ',
          children: [
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: Icons.upload_file,
                  title: 'バックアップを書き出す',
                  subtitle: '曲・プレイリスト・タグ・AB 区間を 1 つのファイルに',
                  onTap: _busy ? null : _exportData,
                ),
                SettingsRow(
                  icon: Icons.download,
                  title: 'バックアップから復元',
                  subtitle: '今のデータは置き換わります',
                  onTap: _busy ? null : _importData,
                ),
              ],
            ),
          ],
        ),
        if (_busy)
          Container(
            color: Colors.black38,
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
