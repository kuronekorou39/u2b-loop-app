import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/storage/app_boxes.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/app_version.dart';

/// 入れられる新しい版
class UpdateOffer {
  const UpdateOffer({required this.tag, required this.version, required this.apkUrl});

  /// タグ名から v を除いたもの（`1.158.0-beta.1`）
  final String tag;
  final AppVersion version;
  final String apkUrl;
}

/// GitHub Releases を見て新しい版を知らせる。
///
/// ふつうは `releases/latest`（プレリリースは返らない）。テスト版も受け取る設定
/// （デバッグモードの中）がオンの端末だけ、プレリリースも含めた一覧から一番新しいものを探す。
/// テスト版は `v1.158.0-beta.1` のようにハイフン付きのタグで出す（CI がプレリリースにする）
class UpdateService {
  static const _repo = 'kuronekorou39/u2b-loop-app';
  static const _timeout = Duration(seconds: 10);

  static bool get includeBeta =>
      AppBoxes.settings.get(SettingsKeys.betaUpdates, defaultValue: false)
          as bool;

  /// 更新があればダイアログを出す。[manual]（設定から押したとき）は、無いときも結果を知らせる
  static Future<void> checkForUpdate(BuildContext context,
      {bool manual = false}) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = AppVersion.tryParse(info.version);
      if (current == null) return;
      final beta = includeBeta;
      final releases = await _fetch(beta);
      final offer = pickUpdate(releases, current, includeBeta: beta);
      if (offer == null) {
        if (manual) {
          AppToast.instance.show(AppSnackBar.info('最新版です（v${info.version}）'));
        }
        return;
      }
      if (!context.mounted) return;
      if (manual) AppToast.instance.hide();
      _showUpdateDialog(context, offer);
    } catch (_) {
      // 起動時の確認は黙って諦める
      if (manual) {
        AppToast.instance.show(AppSnackBar.error('更新を確認できませんでした'));
      }
    }
  }

  static Future<List<dynamic>> _fetch(bool beta) async {
    final client = HttpClient();
    try {
      final path = beta ? 'releases?per_page=30' : 'releases/latest';
      final request = await client
          .getUrl(Uri.parse('https://api.github.com/repos/$_repo/$path'))
          .timeout(_timeout);
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('GitHub ${response.statusCode}');
      }
      final json = jsonDecode(await response.transform(utf8.decoder).join());
      return json is List ? json : [json];
    } finally {
      client.close();
    }
  }

  /// [releases]（GitHub の release の JSON）から、[current] より新しく APK の付いた
  /// 一番新しい版を選ぶ。無ければ null。[includeBeta] でなければプレリリースは見ない
  static UpdateOffer? pickUpdate(List<dynamic> releases, AppVersion current,
      {required bool includeBeta}) {
    UpdateOffer? best;
    for (final r in releases) {
      if (r is! Map || r['draft'] == true) continue;
      final tag = r['tag_name'] as String? ?? '';
      final version = AppVersion.tryParse(tag);
      if (version == null) continue;
      if (!includeBeta && (version.isPrerelease || r['prerelease'] == true)) {
        continue;
      }
      if (!(version > current)) continue;
      if (best != null && !(version > best.version)) continue;
      String? url;
      for (final a in r['assets'] as List<dynamic>? ?? const []) {
        if ((a['name'] as String? ?? '').endsWith('.apk')) {
          url = a['browser_download_url'] as String?;
          break;
        }
      }
      if (url == null) continue;
      best = UpdateOffer(
          tag: tag.startsWith('v') ? tag.substring(1) : tag,
          version: version,
          apkUrl: url);
    }
    return best;
  }

  static void _showUpdateDialog(BuildContext context, UpdateOffer offer) {
    final kind = offer.version.isPrerelease ? '（テスト版）' : '';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アップデートがあります'),
        content: Text('v${offer.tag}$kind が利用可能です。\nダウンロードしてインストールしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('あとで'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse(offer.apkUrl),
                  mode: LaunchMode.externalApplication);
            },
            child: const Text('ダウンロード'),
          ),
        ],
      ),
    );
  }
}
