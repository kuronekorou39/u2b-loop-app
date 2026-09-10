import 'package:flutter/material.dart';

/// アプリ共通のダイアログ。
///
/// 以前は名前入力ダイアログが6ファイル12箇所、削除確認が5箇所にコピペされており、
/// ボタン文言・maxLength・trim の有無・controller の後始末が箇所ごとに違っていた。
class AppDialogs {
  AppDialogs._();

  /// 1行のテキストを入力させる。
  ///
  /// 戻り値は trim 済みの入力文字列。キャンセル時と空文字のときは null。
  /// controller の破棄はこの中で面倒を見る。
  static Future<String?> prompt(
    BuildContext context, {
    required String title,
    String initialValue = '',
    String? hintText,
    String confirmLabel = 'OK',
    int? maxLength,
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: maxLength,
          decoration: InputDecoration(
            hintText: hintText,
            isDense: true,
            border: const OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return null;
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
