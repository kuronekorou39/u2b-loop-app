import 'dart:math';

import 'package:flutter/material.dart';

import '../core/ui/app_snack_bar.dart';
import '../core/utils/app_errors.dart';
import '../models/loop_item.dart';
import 'export_service.dart';
import 'export_source.dart';

/// 書き出しの形式・解像度・音質（保存シート SaveFlow で決まる）
class ExportChoice {
  const ExportChoice(this.format,
      {this.quality = ExportQuality.p360, this.hqAudio = true});

  final ExportFormat format;
  final ExportQuality quality;

  /// 音声のみで高音質の音声を使うか（false = 一体型の 96kbps）
  final bool hqAudio;

  bool get audioOnly => format == ExportFormat.audioOnly;
}

/// 曲を書き出す（保存シート SaveFlow から）。
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
    hqAudio: choice.hqAudio,
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
