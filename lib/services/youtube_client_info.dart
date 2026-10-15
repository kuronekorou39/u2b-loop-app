import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// YouTube の innertube API に名乗るクライアント情報。
///
/// バージョンを上げるときは1箇所で済むよう、ここ以外に書かないこと
/// （以前は youtube_service と subtitle_service に同じ値が散っていて、
/// 片方だけ古いまま取り残される形になっていた）。
///
/// TVクライアントはBot判定されやすいため Android ベースを使う。
class YouTubeClientInfo {
  /// 音声専用ストリームを PO トークン無しで最後まで落とせるクライアント（visionOS の YouTube アプリ）。
  ///
  /// ANDROID / ANDROID_VR 等の音声専用 URL は 2026 年時点で先頭 1MB しか返さず以降 403
  /// （PO トークン要求）。yt-dlp 2026.08 が既定で使う VISIONOS はこの制限が無く、n パラメータの
  /// 復号も要らない。bot 判定を避けるのに visitorData が要るが、youtube_explode_dart が
  /// watch ページから自動で付ける（requireWatchPage 既定 true）。
  /// 一体型（muxed）は返さないので、映像の土台には使わない
  static const visionOs = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
    'contentCheckOk': true,
    'racyCheckOk': true,
  }, playerEndpoint);

  YouTubeClientInfo._();

  static const clientName = 'ANDROID';
  static const clientVersion = '20.10.38';
  static const androidSdkVersion = 30;
  static const androidVersion = '11';

  static const userAgent =
      'com.google.android.youtube/$clientVersion (Linux; U; Android $androidVersion) gzip';

  static const playerEndpoint =
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

  /// innertube リクエストの context.client 部分。
  /// [hl] は表示言語（字幕名の言語などに効く）。
  static Map<String, dynamic> context({String hl = 'en'}) => {
        'clientName': clientName,
        'clientVersion': clientVersion,
        'androidSdkVersion': androidSdkVersion,
        'userAgent': userAgent,
        'hl': hl,
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
        'osName': 'Android',
        'osVersion': androidVersion,
      };
}
