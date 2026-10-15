import 'package:flutter/material.dart';

import '../../core/ui/app_sheets.dart';
import '../../services/subtitle_service.dart';

/// 字幕の言語を選ぶシート（字幕ボタンの長押し）。
/// 「メイン」と「サブ（小さく表示）」の 2 段。トラックが無ければ何も出さない
Future<void> showSubtitleLanguageSheet(
  BuildContext context, {
  required List<SubtitleTrackInfo> tracks,
  required String? mainLanguage,
  required String? subLanguage,
  required void Function(SubtitleTrackInfo track) onMain,
  required void Function(SubtitleTrackInfo track) onSub,
  required VoidCallback onClearSub,
}) {
  if (tracks.isEmpty) return Future.value();

  String label(SubtitleTrackInfo t) =>
      t.languageName.isNotEmpty ? t.languageName : t.languageCode;

  return AppSheets.actions(
    context,
    title: '字幕の言語',
    actions: [
      const SheetAction.heading('メイン'),
      for (final track in tracks)
        SheetAction(
          icon: Icons.subtitles,
          label: label(track),
          selected: track.languageCode == mainLanguage,
          onTap: () => onMain(track),
        ),
      const SheetAction.heading('サブ（小さく表示）'),
      SheetAction(
        icon: Icons.subtitles_off,
        label: 'なし',
        selected: subLanguage == null,
        onTap: onClearSub,
      ),
      for (final track in tracks)
        SheetAction(
          icon: Icons.subtitles,
          label: label(track),
          selected: track.languageCode == subLanguage,
          onTap: () => onSub(track),
        ),
    ],
  );
}
