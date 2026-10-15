import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../services/playback/hq_audio.dart';

/// 高音質の音声（HqAudio）の取得・取り付けの記録を見せる。
/// 端末では logcat を読めないので、落とせない原因をこれで確かめる。コピーもできる
class HqAudioLogDialog extends StatelessWidget {
  const HqAudioLogDialog({super.key});

  static Future<void> show(BuildContext context) =>
      showDialog(context: context, builder: (_) => const HqAudioLogDialog());

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .labelSmall!
        .copyWith(fontFamily: 'monospace', height: 1.4);
    return AlertDialog(
      title: const Text('高音質のログ'),
      content: SizedBox(
        width: double.maxFinite,
        child: ValueListenableBuilder<int>(
          valueListenable: HqAudio.logVersion,
          builder: (context, _, _) {
            final lines = HqAudio.recentLog;
            if (lines.isEmpty) {
              return Text('まだ記録がありません。YouTube の曲を再生してから見てください',
                  style: TextStyle(color: AppTheme.muted(context)));
            }
            return SingleChildScrollView(
              child: SelectableText(lines.join('\n'), style: style),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: HqAudio.recentLog.join('\n')));
            ScaffoldMessenger.of(context)
                .showSnackBar(AppSnackBar.success('ログをコピーしました'));
          },
          child: const Text('コピー'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}
