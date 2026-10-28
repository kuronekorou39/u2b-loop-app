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
    if (e is VideoUnplayableException) return _unplayable(e.toString());
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

  /// 再生できない理由ごとの文。YouTube が返す理由（英語。表示言語によっては日本語）の
  /// 決まり文句で見分ける。上から順に見て最初に当たったもの
  static final _unplayableRules = <(RegExp, String)>[
    (
      // 「Sign in to confirm your age」「This video may be inappropriate for some users.」
      // （内容の警告「…to some viewers」は contentCheckOk で通るのでここには来ない）
      _r(r'confirm your age|age[- ]restrict|inappropriate for some users|年齢|一部のユーザーに適さない'),
      '年齢制限のある動画です。YouTube にログインしないと再生できないため、このアプリでは開けません',
    ),
    (
      _r(r'not a bot|ボットでない'),
      'YouTube にボットと判定されました。少し時間をおいてやり直してください',
    ),
    (
      _r(r'members[- ]only|join this channel|メンバー'),
      'チャンネルのメンバー限定の動画です',
    ),
    (
      _r(r'country|region|お住まいの国|地域'),
      'この地域では再生できない動画です（地域制限）',
    ),
    (
      _r(r'private|非公開'),
      '非公開の動画です',
    ),
    (
      _r(r'live stream|live event|premiere|ライブ|プレミア'),
      'ライブ配信中・配信前の動画は再生できません',
    ),
    (
      _r(r'removed|terminated|削除'),
      '削除された動画です',
    ),
  ];

  static RegExp _r(String pattern) => RegExp(pattern, caseSensitive: false);

  static String _unplayable(String message) {
    // youtube_explode_dart は「…Reason: <YouTube の理由>」の形で投げる。
    // ライブ配信中は理由が無く、本文に「ongoing live stream」とある
    final match = RegExp(r'Reason:\s*(.*)$', dotAll: true).firstMatch(message);
    final reason = match?.group(1)?.trim() ?? '';
    final text = reason.isEmpty ? message : reason;
    for (final (pattern, label) in _unplayableRules) {
      if (pattern.hasMatch(text)) return label;
    }
    if (reason.isEmpty) return '再生できない動画です';
    final shown = reason.length > _maxLength
        ? '${reason.substring(0, _maxLength)}…'
        : reason;
    return '再生できない動画です（YouTube: $shown）';
  }
}
