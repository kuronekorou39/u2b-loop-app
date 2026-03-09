import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateService {
  static const _repo = 'kuronekorou39/u2b-loop-app';

  /// GitHub Releases の最新版をチェックし、更新があればダイアログを表示
  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version; // e.g. "1.0.0"

      final client = HttpClient();
      try {
        final request = await client
            .getUrl(
                Uri.parse('https://api.github.com/repos/$_repo/releases/latest'))
            .timeout(const Duration(seconds: 10));
        request.headers.set('Accept', 'application/vnd.github.v3+json');
        final response =
            await request.close().timeout(const Duration(seconds: 10));

        if (response.statusCode != 200) return;

        final body =
            await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        final tagName = json['tag_name'] as String? ?? '';
        // "v1.2.0" → "1.2.0"
        final latestVersion =
            tagName.startsWith('v') ? tagName.substring(1) : tagName;

        if (!_isNewer(latestVersion, currentVersion)) return;

        // APKのダウンロードURLを取得
        String? apkUrl;
        final assets = json['assets'] as List<dynamic>? ?? [];
        for (final asset in assets) {
          final name = asset['name'] as String? ?? '';
          if (name.endsWith('.apk')) {
            apkUrl = asset['browser_download_url'] as String?;
            break;
          }
        }

        if (apkUrl == null) return;

        if (!context.mounted) return;
        _showUpdateDialog(context, latestVersion, apkUrl);
      } finally {
        client.close();
      }
    } catch (_) {
      // ネットワークエラー等は無視
    }
  }

  /// バージョン比較: latest が current より新しいか
  static bool _isNewer(String latest, String current) {
    final lParts = latest.split('.').map(int.tryParse).toList();
    final cParts = current.split('.').map(int.tryParse).toList();

    for (var i = 0; i < 3; i++) {
      final l = i < lParts.length ? (lParts[i] ?? 0) : 0;
      final c = i < cParts.length ? (cParts[i] ?? 0) : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  static void _showUpdateDialog(
      BuildContext context, String version, String apkUrl) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アップデートがあります'),
        content: Text('v$version が利用可能です。\nダウンロードしてインストールしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('あとで'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse(apkUrl),
                  mode: LaunchMode.externalApplication);
            },
            child: const Text('ダウンロード'),
          ),
        ],
      ),
    );
  }
}
