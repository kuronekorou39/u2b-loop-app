import 'dart:math';

import 'package:flutter/material.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/app_errors.dart';
import '../models/loop_item.dart';
import 'export_service.dart';
import 'export_source.dart';

/// 書き出しダイアログで決まったこと（形式と、MP4 なら解像度）
class ExportChoice {
  const ExportChoice(this.format, {this.quality = ExportQuality.p360});

  final ExportFormat format;
  final ExportQuality quality;

  bool get audioOnly => format == ExportFormat.audioOnly;
}

/// 書き出し形式（音声のみ / MP4）を選ぶダイアログ。キャンセルは null。
/// [rangeText] は「0:12 - 1:30 (78.0s)」のような区間の説明。
/// [askQuality]（YouTube を MP4 で）なら続けて解像度も聞く。前回の選択を覚えておく。
/// 再生画面・AB 設定画面・曲の詳細で 3 つずつ別に書かれていたものを 1 つに
Future<ExportChoice?> showExportFormatDialog(
  BuildContext context, {
  required String title,
  String? rangeText,
  bool askQuality = false,
}) async {
  final format = await showDialog<ExportFormat>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: rangeText == null
          ? null
          : Text(rangeText, style: Theme.of(ctx).textTheme.bodyMedium),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('キャンセル'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.pop(ctx, ExportFormat.audioOnly),
          icon: const Icon(Icons.audiotrack, size: AppIconSizes.s),
          label: const Text('音声のみ'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.pop(ctx, ExportFormat.mp4),
          icon: const Icon(Icons.videocam, size: AppIconSizes.s),
          label: const Text('MP4'),
        ),
      ],
    ),
  );
  if (format == null) return null;
  if (format != ExportFormat.mp4 || !askQuality || !context.mounted) {
    return ExportChoice(format);
  }
  final quality = await showExportQualityDialog(context);
  if (quality == null) return null;
  return ExportChoice(format, quality: quality);
}

/// MP4 の解像度を選ぶ。前回の選択を既定にし、選んだら覚える。キャンセルは null
Future<ExportQuality?> showExportQualityDialog(BuildContext context) async {
  final last = ExportQuality.fromName(
      AppBoxes.settings.get(SettingsKeys.exportQuality) as String?);
  final picked = await showDialog<ExportQuality>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('解像度'),
      children: [
        for (final q in ExportQuality.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, q),
            child: Row(
              children: [
                Icon(
                  q == last
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: AppIconSizes.s,
                  color: q == last ? AppTheme.accentGreen : null,
                ),
                const SizedBox(width: AppSpacing.lg),
                Text(q.label),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl + 8, AppSpacing.md, AppSpacing.xl, AppSpacing.sm),
          child: Text(
            '360p 超は映像と高音質の音声を別に取得して結合します（1 曲で数十 MB）',
            style: Theme.of(ctx)
                .textTheme
                .bodySmall!
                .copyWith(color: AppTheme.muted(ctx)),
          ),
        ),
      ],
    ),
  );
  if (picked != null) AppBoxes.settings.put(SettingsKeys.exportQuality, picked.name);
  return picked;
}

/// 曲を書き出す（3 画面共通の入口）。
///
/// YouTube の曲は [ExportSource] が高画質・高音質の入力を用意する
/// （音声のみ → 高音質の音声、360p 超 → 映像専用 + 高音質の音声を結合）。
/// 用意できなければ [fallbackUri]（再生に使っている一体型 360p）で書き出し、その旨を出す。
/// ローカル動画とオフライン保存済みは [fallbackUri] をそのまま使う
Future<void> runItemExportFlow(
  BuildContext context, {
  required LoopItem item,
  required String fallbackUri,
  required int startMs,
  required int endMs,
  required ExportChoice choice,
  required String title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void status(String text) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(AppSnackBar.progress(text));
  }

  final input = await ExportSource.prepare(
    item,
    format: choice.format,
    quality: choice.quality,
    fallbackUri: fallbackUri,
    onStatus: status,
  );
  messenger.hideCurrentSnackBar();
  if (input.note != null) {
    messenger.showSnackBar(AppSnackBar.info(input.note!));
    // 読める間だけ見せてから書き出しの進捗に切り替える
    await Future.delayed(const Duration(seconds: 2));
  }
  try {
    if (!context.mounted) return;
    await runExportFlow(
      context,
      inputUri: input.path,
      startMs: startMs,
      endMs: endMs,
      format: choice.format,
      title: title,
    );
  } finally {
    await input.dispose();
  }
}

/// 書き出しの共通フロー。
///
/// 進捗SnackBar表示 → [ExportService.exportRegion] → 結果処理
/// （ギャラリー保存済みなら通知、Android 9以前は共有シートへフォールバック）。
/// 呼び出し側は解決済みの [inputUri]（local=元URI、YouTube=stream URL か結合済みの一時ファイル）を渡す。
///
/// [startMs] > [endMs] の場合は自動で正規化する（A>B指定でもネイティブ書き出しが失敗しない）。
Future<void> runExportFlow(
  BuildContext context, {
  required String inputUri,
  required int startMs,
  required int endMs,
  required ExportFormat format,
  required String title,
}) async {
  final start = min(startMs, endMs);
  final end = max(startMs, endMs);

  // メッセンジャは画面pop後も有効なアプリ単位の参照。await跨ぎでも安全。
  final messenger = ScaffoldMessenger.of(context);

  if (end - start <= 0) {
    messenger.showSnackBar(
      AppSnackBar.info('書き出す区間の長さがありません'),
    );
    return;
  }

  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    AppSnackBar.progress('書き出し中...'),
  );

  final service = ExportService();
  final result = await service.exportRegion(
    inputUri: inputUri,
    startMs: start,
    endMs: end,
    format: format,
    title: title,
  );

  messenger.hideCurrentSnackBar();

  if (!result.success) {
    messenger.showSnackBar(
      AppSnackBar.error('書き出し失敗: ${result.error}',
          duration: const Duration(seconds: 8)),
    );
    return;
  }

  // 端末のギャラリー（フォト）/ミュージックへ直接保存済み（API 29+）。
  if (result.savedToGallery) {
    final loc = result.outputPath;
    final head = format == ExportFormat.audioOnly ? '保存しました' : 'フォトに保存しました';
    messenger.showSnackBar(
      AppSnackBar.success(loc != null ? '$head\n$loc' : head,
          duration: const Duration(seconds: 4)),
    );
    return;
  }

  // Android 9以前は書込権限が必要なため共有シートにフォールバック。
  // ファイルをDartのメモリに読み込まずパスで渡すため、長尺MP4でもOOMしない。
  final safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  try {
    await service.shareExported(
      outputPath: result.outputPath!,
      format: format,
      subject: safeTitle,
    );
  } catch (e) {
    messenger.showSnackBar(
      AppSnackBar.error('共有に失敗しました: ${AppErrors.describe(e)}'),
    );
  }
}
