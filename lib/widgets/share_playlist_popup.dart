import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/ui/share_origin.dart';
import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_sheets.dart';
import '../core/ui/app_snack_bar.dart';
import 'player/more_tile.dart';

/// プレイリストの共有。ボタンの集まりなので、その他メニューと同じ真ん中のポップアップで出す
class SharePlaylistPopup extends StatelessWidget {
  const SharePlaylistPopup({
    super.key,
    required this.name,
    required this.songCount,
    required this.url,
  });

  final String name;
  final int songCount;
  final String url;

  /// タイル 3 つがちょうど 1 行に入る幅（広いと横画面で右に 1 列ぶん空く）
  static const maxWidth =
      MoreTileGrid.maxExtentShort * 3 + AppSpacing.md * 2 + AppSpacing.xl * 2;

  static Future<void> show(
    BuildContext context, {
    required String name,
    required int songCount,
    required String url,
  }) =>
      AppSheets.popup<void>(
        context,
        maxWidth: maxWidth,
        builder: (_) =>
            SharePlaylistPopup(name: name, songCount: songCount, url: url),
      );

  void _copy(BuildContext context) {
    Navigator.pop(context);
    Clipboard.setData(ClipboardData(text: url));
    AppToast.instance.show(AppSnackBar.success('URL をコピーしました'));
  }

  void _showQr(BuildContext context) {
    final navigator = Navigator.of(context)..pop();
    AppSheets.popup<void>(
      navigator.context,
      maxWidth: _QrPopup.maxWidth,
      builder: (_) => _QrPopup(name: name, url: url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: AppSpacing.md),
                Text('$songCount 曲', style: textTheme.bodySmall),
              ],
            ),
          ),
          MoreTileGrid(tiles: [
            MoreTile(
              icon: Icons.share_outlined,
              label: '送る',
              onTap: () {
                Navigator.pop(context);
                Share.share(url, sharePositionOrigin: shareOrigin());
              },
            ),
            MoreTile(
              icon: Icons.content_copy,
              label: 'コピー',
              onTap: () => _copy(context),
            ),
            // 長すぎて QR にできないときも、場所は残して押せないだけにする
            MoreTile(
              icon: Icons.qr_code,
              label: 'QR コード',
              enabled: url.length <= AppLimits.qrMaxLength,
              onTap: () => _showQr(context),
            ),
          ]),
        ],
      ),
    );
  }
}

/// 共有リンクの QR コード。低い画面（横向き）でも全体が入るよう、残りの高さに合わせて縮む
class _QrPopup extends StatelessWidget {
  const _QrPopup({required this.name, required this.url});

  final String name;
  final String url;

  static const maxWidth = 400.0;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  // テーマに関係なく白地（読み取りには周りの白い余白も要る）
                  child: QrImageView(
                    data: url,
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.all(AppSpacing.lg),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
