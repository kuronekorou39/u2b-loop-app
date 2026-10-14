import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';

/// 区間の A・B の時刻を手で打つダイアログ。入力は「1:23.5」でも「83.5」（秒）でもよい。
/// 空欄は未設定。読めない値と A ≧ B はその場でエラーを出して保存を止める
/// （以前は秒の小数だけで検証が無く、数字でない値を入れると点が黙って消えていた）。
///
/// 戻り値は保存したときのミリ秒。キャンセルは null
Future<({int? aMs, int? bMs})?> showRegionTimeDialog(
  BuildContext context, {
  required String title,
  int? aMs,
  int? bMs,
}) {
  return showDialog<({int? aMs, int? bMs})>(
    context: context,
    builder: (_) => _RegionTimeDialog(title: title, aMs: aMs, bMs: bMs),
  );
}

class _RegionTimeDialog extends StatefulWidget {
  const _RegionTimeDialog({required this.title, this.aMs, this.bMs});

  final String title;
  final int? aMs;
  final int? bMs;

  @override
  State<_RegionTimeDialog> createState() => _RegionTimeDialogState();
}

class _RegionTimeDialogState extends State<_RegionTimeDialog> {
  late final _a = TextEditingController(text: _initial(widget.aMs));
  late final _b = TextEditingController(text: _initial(widget.bMs));

  static String _initial(int? ms) =>
      ms == null ? '' : TimeUtils.format(Duration(milliseconds: ms));

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  /// 空欄は null（未設定）、読めなければ error
  ({Duration? value, String? error}) _read(String text) {
    final t = text.trim();
    if (t.isEmpty) return (value: null, error: null);
    final d = TimeUtils.parseFlexible(t);
    if (d == null) return (value: null, error: '「1:23.5」か秒数で入力してください');
    return (value: d, error: null);
  }

  @override
  Widget build(BuildContext context) {
    final a = _read(_a.text);
    final b = _read(_b.text);
    String? orderError;
    if (a.value != null && b.value != null && a.value! >= b.value!) {
      orderError = 'B は A より後にしてください';
    }
    final canSave = a.error == null && b.error == null && orderError == null;

    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _a,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'A',
              hintText: '例: 0:10.5',
              errorText: a.error,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _b,
            decoration: InputDecoration(
              labelText: 'B',
              hintText: '例: 0:45',
              errorText: b.error ?? orderError,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('空欄にすると未設定になります',
              style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: canSave
              ? () => Navigator.pop(context, (
                    aMs: a.value?.inMilliseconds,
                    bMs: b.value?.inMilliseconds,
                  ))
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
