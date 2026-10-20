import 'package:flutter/material.dart';

/// アプリ共通のダイアログ。
///
/// 以前は名前入力ダイアログが6ファイル12箇所、削除確認が5箇所にコピペされており、
/// ボタン文言・maxLength・trim の有無・controller の後始末が箇所ごとに違っていた。
class AppDialogs {
  AppDialogs._();

  /// テキストを入力させる（既定は 1 行）。
  ///
  /// 戻り値は trim 済みの入力文字列。キャンセル時は null。空文字のときも null
  /// （[allowEmpty] なら '' を返す。メモを消すときなど）。
  /// controller はダイアログが持ち、閉じ終わってから破棄する
  /// （pop の直後に破棄すると、閉じるアニメーション中に使われて落ちる）。
  ///
  /// [maxLength] は入力中には切り詰めない。TextField の maxLength に任せると、
  /// 上限を超えた初期値（取り込んだ長い曲名など）を 1 文字消しただけで
  /// 末尾が上限までまとめて消える。超えている間は文字数を赤く出して OK を押せなくする
  static Future<String?> prompt(
    BuildContext context, {
    required String title,
    String initialValue = '',
    String? hintText,
    String confirmLabel = 'OK',
    int? maxLength,
    int maxLines = 1,
    int? minLines,
    bool allowEmpty = false,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        title: title,
        initialValue: initialValue,
        hintText: hintText,
        confirmLabel: confirmLabel,
        maxLength: maxLength,
        maxLines: maxLines,
        minLines: minLines,
      ),
    );
    if (result == null) return null;
    if (result.isEmpty && !allowEmpty) return null;
    return result;
  }

  /// 削除の確認。削除してよければ true。
  static Future<bool> confirmDelete(
    BuildContext context, {
    required String message,
    String title = '削除確認',
    String confirmLabel = '削除',
  }) async {
    final result = await showDialog<bool>(
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
            child: Text(confirmLabel,
                style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// はい/いいえの確認（削除以外の後戻りしにくい操作）。
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'キャンセル',
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel,
                style: destructive ? const TextStyle(color: Colors.red) : null),
          ),
        ],
      ),
    );
    return result == true;
  }
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initialValue,
    required this.hintText,
    required this.confirmLabel,
    required this.maxLength,
    required this.maxLines,
    required this.minLines,
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final String confirmLabel;
  final int? maxLength;
  final int maxLines;
  final int? minLines;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final maxLength = widget.maxLength;
        final length = value.text.characters.length;
        final over = maxLength != null && length > maxLength;
        void submit() {
          if (!over) Navigator.pop(context, _controller.text.trim());
        }

        return AlertDialog(
          title: Text(widget.title),
          // 横画面でキーボードが出ても溢れないように
          scrollable: widget.maxLines > 1,
          content: TextField(
            controller: _controller,
            autofocus: true,
            maxLines: widget.maxLines,
            minLines: widget.minLines,
            decoration: InputDecoration(
              hintText: widget.hintText,
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: over ? '$length / $maxLength 文字' : null,
            ),
            onSubmitted: widget.maxLines == 1 ? (_) => submit() : null,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: over ? null : submit,
              child: Text(widget.confirmLabel),
            ),
          ],
        );
      },
    );
  }
}
