import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'advance_stage.dart';

typedef _Parts = ({Widget topBar, Widget band, Widget bottomBar});

/// 重ね表示の棒 2 本と帯。組が次へ進んだら（[pairKey] が変わったら）[AdvanceStage] の
/// 3 拍子で入れ替える:
/// 1. 前曲の段（帯の上の段と前曲の棒）が左へ抜ける
/// 2. 次曲の段（帯の下の段と次曲の棒）が上がって前曲の段になる。窓（描く範囲）が
///    組ごとに違うので中身まで同じにはできず、上がりながら新しい前曲の段に溶ける
/// 3. 新しい次曲の段（帯の下の段と棒）が右から入ってくる
///
/// 動いていないときは 3 つを縦に並べるだけ（帯は 1 枚、ふだんの描画と同じ）。
/// 動いている間は帯を上下半分に切って（[OverflowBox] + [ClipRect]）別々に動かす
class MixLanesAdvance extends StatelessWidget {
  const MixLanesAdvance({
    super.key,
    required this.pairKey,
    required this.topBar,
    required this.band,
    required this.bottomBar,
    required this.topBarHeight,
    required this.bandHeight,
    required this.bottomBarHeight,
    this.gap = AppSpacing.xs,
  });

  /// どの組か。変わったら動く
  final Key pairKey;

  final Widget topBar;
  final Widget band;
  final Widget bottomBar;

  final double topBarHeight;
  final double bandHeight;
  final double bottomBarHeight;

  /// 棒と帯の隙間
  final double gap;

  double get height => topBarHeight + gap + bandHeight + gap + bottomBarHeight;

  @override
  Widget build(BuildContext context) => AdvanceStage<_Parts>(
        stageKey: pairKey,
        value: (topBar: topBar, band: band, bottomBar: bottomBar),
        builder: _build,
      );

  Widget _build(
    BuildContext context,
    _Parts current,
    _Parts? previous,
    AdvancePhases phases,
  ) {
    if (previous == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          current.topBar,
          SizedBox(height: gap),
          current.band,
          SizedBox(height: gap),
          current.bottomBar,
        ],
      );
    }
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final laneH = bandHeight / 2;
          final yBand = topBarHeight + gap;
          final yLower = yBand + laneH;
          final yBottomBar = yBand + bandHeight + gap;
          final leave = phases.leave;
          final rise = phases.rise;
          final enter = phases.enter;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // 1. 前曲の段は左へ抜ける
              if (leave < 1) ...[
                _place(
                  left: -w * leave,
                  top: 0,
                  width: w,
                  opacity: 1 - leave,
                  child: SizedBox(height: topBarHeight, child: previous.topBar),
                ),
                _place(
                  left: -w * leave,
                  top: yBand,
                  width: w,
                  opacity: 1 - leave,
                  child: _half(previous.band, w, upper: true),
                ),
              ],
              // 新しい前曲の段（次曲が上がってくるのに合わせて現れる）
              _place(
                left: 0,
                top: 0,
                width: w,
                opacity: rise,
                child: SizedBox(height: topBarHeight, child: current.topBar),
              ),
              _place(
                left: 0,
                top: yBand,
                width: w,
                opacity: rise,
                child: _half(current.band, w, upper: true),
              ),
              // 2. 次曲の段が上がる（上がりながら新しい前曲の段に溶ける）
              if (rise < 1) ...[
                _place(
                  left: 0,
                  top: yLower - laneH * rise,
                  width: w,
                  opacity: 1 - rise,
                  child: _half(previous.band, w, upper: false),
                ),
                _place(
                  left: 0,
                  top: yBottomBar * (1 - rise),
                  width: w,
                  opacity: 1 - rise,
                  child: SizedBox(
                      height: bottomBarHeight, child: previous.bottomBar),
                ),
              ],
              // 3. 新しい次曲の段が右から入ってくる
              _place(
                left: w * (1 - enter),
                top: yLower,
                width: w,
                opacity: enter,
                child: _half(current.band, w, upper: false),
              ),
              _place(
                left: w * (1 - enter),
                top: yBottomBar,
                width: w,
                opacity: enter,
                child:
                    SizedBox(height: bottomBarHeight, child: current.bottomBar),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 帯の上半分（前曲の段）か下半分（次曲の段）だけを見せる
  Widget _half(Widget band, double width, {required bool upper}) => SizedBox(
        width: width,
        height: bandHeight / 2,
        child: ClipRect(
          child: OverflowBox(
            alignment: upper ? Alignment.topCenter : Alignment.bottomCenter,
            minHeight: bandHeight,
            maxHeight: bandHeight,
            child: band,
          ),
        ),
      );

  static Widget _place({
    required double left,
    required double top,
    required double width,
    required double opacity,
    required Widget child,
  }) =>
      Positioned(
        left: left,
        top: top,
        width: width,
        child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
      );
}
