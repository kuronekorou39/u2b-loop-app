/// YouTube の innertube API に名乗るクライアント情報。
///
/// バージョンを上げるときは1箇所で済むよう、ここ以外に書かないこと
/// （以前は youtube_service と subtitle_service に同じ値が散っていて、
/// 片方だけ古いまま取り残される形になっていた）。
///
/// TVクライアントはBot判定されやすいため Android ベースを使う。
class YouTubeClientInfo {
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
