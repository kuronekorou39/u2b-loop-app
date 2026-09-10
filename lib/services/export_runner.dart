import 'dart:math';

import 'package:flutter/material.dart';

import 'export_service.dart';
import '../core/ui/app_snack_bar.dart';

/// 書き出しの共通フロー。
///
/// 進捗SnackBar表示 → [ExportService.exportRegion] → 結果処理
/// （ギャラリー保存済みなら通知、Android 9以前は共有シートへフォールバック）。
/// 呼び出し側は解決済みの [inputUri]（local=元URI、YouTube=stream URL）を渡す。
///
/// player_screen / editor_screen / detail_screen で重複していた約90行を集約。
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
      AppSnackBar.error('共有に失敗しました: $e'),
    );
  }
}
