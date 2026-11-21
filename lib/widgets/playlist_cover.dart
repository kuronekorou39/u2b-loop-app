import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// プレイリストの表紙。サムネの上に少しずつ狭い板を 2 枚ずらして覗かせ（曲の束に見せる）、
/// 左下に曲数の札を出す。1 曲のサムネ（ItemThumbnail）と形で見分けられるように
/// （どちらもサムネ 1 枚だけだと、一覧で曲とプレイリストの区別がつかなかった）。
/// 幅は親いっぱい、高さは板の分 + 幅 / [aspectRatio]
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({
    super.key,
    required this.image,
    required this.count,
    this.aspectRatio = 1,
    this.radius = 10,
    this.compact = false,
    this.overlays = const [],
  });

  /// サムネ（無いときはその代わりの面）
  final Widget image;

  /// 曲数（左下の札）
  final int count;

  /// サムネの縦横比（グリッドは正方形のジャケット）
  final double aspectRatio;
  final double radius;

  /// リストの行の小さい表紙。板と札を小さく
  final bool compact;

  /// サムネの上に重ねるもの（Stack の子: 鳴っている印・再生ボタン・選択の印など）。札より下
  final List<Widget> overlays;

  /// 板 1 枚の見えている高さ
  static double plateHeightOf({required bool compact}) => compact ? 3 : 4;

  /// 板と板・板とサムネの間
  static const plateGap = 1.0;

  /// 板 2 枚ぶんの高さ（表紙の上に取る）
  static double stackHeightOf({required bool compact}) =>
      (plateHeightOf(compact: compact) + plateGap) * 2;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final ink = AppTheme.ink(brightness);
    final plateHeight = plateHeightOf(compact: compact);
    // 1 枚奥へ行くごとに左右をこれだけ狭め、薄くする
    final inset = compact ? 4.0 : 8.0;
    final nearAlpha = brightness == Brightness.dark ? 0.32 : 0.22;
    Widget plate(int depth) => Padding(
          padding: EdgeInsets.symmetric(horizontal: inset * depth),
          child: Container(
            height: plateHeight,
            decoration: BoxDecoration(
              color: ink.withValues(alpha: nearAlpha / depth),
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(radius / 2)),
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        plate(2),
        const SizedBox(height: plateGap),
        plate(1),
        const SizedBox(height: plateGap),
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                ...overlays,
                Positioned(
                  left: compact ? 2 : 4,
                  bottom: compact ? 2 : 4,
                  child: PlaylistCountBadge(count: count, compact: compact),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 表紙の左下の曲数の札（≡▶ 12）。サムネの上なので明るさに関係なく暗い地に白
class PlaylistCountBadge extends StatelessWidget {
  const PlaylistCountBadge({super.key, required this.count, this.compact = false});

  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 3 : 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: AppRadius.borderXs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.playlist_play,
              size: compact ? AppIconSizes.xs - 2 : AppIconSizes.xs,
              color: Colors.white),
          SizedBox(width: compact ? 1 : 2),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
          ),
        ],
      ),
    );
  }
}
