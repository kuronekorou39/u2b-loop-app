import 'dart:async';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// 例外を人に見せる文に直す。
///
/// 以前は `'$e'` をそのまま SnackBar やエラー画面に出していて、
/// 「SocketException: Failed host lookup: ...」のような英語の内部文字列が見えていた。
/// よくあるもの（通信・YouTube の非公開/制限・ファイル）は日本語の説明にし、
/// それ以外は型名の前置きを外して短くする。
class AppErrors {
  AppErrors._();

  static const _maxLength = 160;

  static String describe(Object e) {
    if (e is SocketException || e is HandshakeException) {
      return 'ネットワークに接続できません';
    }
    if (e is TimeoutException) {
      return '時間内に応答がありませんでした（通信が遅いか、相手が混んでいます）';
    }
    // 購入が必要・見つからない は VideoUnplayableException のサブクラスなので先に見る
    if (e is VideoRequiresPurchaseException) return '購入が必要な動画です';
    if (e is VideoUnavailableException) {
      return '動画が見つかりません（非公開・削除・限定公開の可能性）';
    }
    if (e is VideoUnplayableException) {
      return '再生できない動画です（年齢制限・地域制限・ライブ配信など）';
    }
    if (e is RequestLimitExceededException) {
      return 'YouTube へのアクセスが多すぎます。少し待ってからやり直してください';
    }
    if (e is TransientFailureException) {
      return 'YouTube が一時的に応答しませんでした。やり直してください';
    }
    if (e is FileSystemException) return 'ファイルを読み書きできません';
    if (e is FormatException) return 'データの形式が読めません';

    // それ以外: 「Exception: 」「Bad state: 」のような型名の前置きを外し、長すぎれば切る
    var text = e.toString().trim();
    text = text.replaceFirst(
        RegExp(r'^([A-Za-z_]*(Exception|Error)|Bad state|Invalid argument(\(s\))?):\s*'),
        '');
    if (text.isEmpty) return '不明なエラー';
    if (text.length > _maxLength) text = '${text.substring(0, _maxLength)}…';
    return text;
  }
}
