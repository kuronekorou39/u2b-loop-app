import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// SnackBar の見た目と表示時間をここに集約する。
///
/// 以前は52箇所すべてで SnackBar を直接組み立てており、表示時間が
/// 未指定 / 1 / 2 / 3 / 4 / 5 / 8 / 30秒 に分散していた
/// （同じ「URLをコピーしました」でも画面によって1秒と4秒だった）。
/// 用途で選べば長さが自然に揃う。
/// アプリ全体の ScaffoldMessenger。画面を閉じた後に終わる裏の処理（まとめて解析など）が
/// 結果を知らせるのに使う。画面の中からは今までどおり ScaffoldMessenger.of(context)
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

class AppSnackBar {
  AppSnackBar._();

  /// 完了通知。読まなくても困らないので短く消す
  static const successDuration = Duration(seconds: 2);

  /// 案内・注意。ひと呼吸読む時間が要る
  static const infoDuration = Duration(seconds: 3);

  /// エラー。原因が書いてあるので長め
  static const errorDuration = Duration(seconds: 5);

  /// 進行中。完了時に `hideCurrentSnackBar()` で消す前提の長さ
  static const progressDuration = Duration(seconds: 30);

  /// 処理が終わったことを伝える
  static SnackBar success(String message, {Duration? duration}) =>
      SnackBar(content: Text(message), duration: duration ?? successDuration);

  /// 操作できない理由や補足を伝える
  static SnackBar info(String message, {Duration? duration}) =>
      SnackBar(content: Text(message), duration: duration ?? infoDuration);

  /// 失敗を伝える
  static SnackBar error(String message, {Duration? duration}) =>
      SnackBar(content: Text(message), duration: duration ?? errorDuration);

  /// 処理中を出しっぱなしにする。呼び出し側が `hideCurrentSnackBar()` で消すこと
  static SnackBar progress(String message) => SnackBar(
        content: Row(
          children: [
            const SizedBox(
                width: AppIconSizes.s,
                height: AppIconSizes.s,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: AppSpacing.lg),
            Expanded(child: Text(message)),
          ],
        ),
        duration: progressDuration,
      );

  /// ボタン付き（キャンセル・元に戻す等）
  static SnackBar action(
    String message, {
    required String label,
    required VoidCallback onPressed,
    Duration? duration,
  }) =>
      SnackBar(
        content: Text(message),
        duration: duration ?? infoDuration,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: label, onPressed: onPressed),
      );
}
