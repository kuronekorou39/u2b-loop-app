import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../glass_panel.dart';
import 'advance_stage.dart';
import 'jog_wheel.dart';
import 'pitch_fader.dart';

typedef _DeckParts = ({Widget out, Widget inCol, Widget fader});

/// デッキの板。重ね表示の間、コントローラーの上に浮かせて出す（動画や曲名に被さってよい。
/// 出しているときはこれがメイン）。帯には重ねない（波形が見えなくなり、操作もかぶる）。
///
/// 左から DJ 機材と同じ並び（ピッチフェーダーは自分のジョグの右隣。真ん中に置くと
/// 2 曲の間のバランスに見えてしまう）:
/// - 前曲の盤: 再生に合わせて回るだけ（鳴っている曲は動かさない）。触れないので脇役として
///   小さく薄く、下端を次曲に揃える。次曲が主役
/// - 次曲のジョグ（[JogWheel]）: 回して拍の位置（位相）を合わせる
/// - 次曲のピッチフェーダー（[PitchFader]）: 拍の間隔（テンポ）を合わせる
///   （BPM の倍/半分の取り違えは曲の詳細のテンポ編集で直す。ここには置かない）
///
/// 各円盤の下にそのデッキのテンポ（BPM × 速度）、フェーダーの下にその値。3 列とも
/// 「物 + 値の行」で下端を揃える。2 つのテンポが揃うと次曲側が緑。
/// 一番下に 1 行: 帯の窓の「−」「＋」、次曲の合わせの保存（ピン）・戻す、
/// 音量の線・拍の線の表示切り替え（常にあり、押せないときは灰色。高さは変えない）。
/// 切り替わった後は次曲側も回る・見るだけ（[jog] / [tempo] が null）。
/// 組が次へ進んだら（[contentKey] が変わったら）帯と同じ 3 拍子（[AdvanceStage]）:
/// 前曲の盤が左へ抜け、次曲の円盤が左へ寄りながら小さくなって前曲の盤になり、
/// 新しい次曲の円盤が右から入ってくる（フェーダーは新しい次曲の値に溶ける）。
/// 値はすべて親が持ち、この板は見せて返すだけ
class MixDeck extends StatelessWidget {
  const MixDeck({
    super.key,
    required this.width,
    required this.outTurns,
    required this.inTurns,
    this.contentKey,
    this.outBpm,
    this.inBpm,
    this.jog,
    this.tempo,
    this.onJog,
    this.onJogEnd,
    this.onTempo,
    this.onTempoEnd,
    this.onSave,
    this.onReset,
    this.onWider,
    this.onNarrower,
    this.showCurves = true,
    this.onShowCurves,
    this.showBeats = true,
    this.onShowBeats,
  });

  /// 帯の窓を広げる「−」・狭める「＋」。null なら押せない
  final VoidCallback? onWider;
  final VoidCallback? onNarrower;

  /// 帯の音量曲線・拍の線を出すか。onXxx が null なら切り替えられない
  final bool showCurves;
  final ValueChanged<bool>? onShowCurves;
  final bool showBeats;
  final ValueChanged<bool>? onShowBeats;

  /// 板の幅（コントローラーの幅に合わせる）
  final double width;

  /// どの組を出しているか。変わったら中身を左へ送って入れ替える
  final Key? contentKey;

  /// 前曲・次曲の盤の回転数（[JogWheel.platterTurns]）
  final double outTurns;
  final double inTurns;

  /// 鳴っているテンポ（BPM × 速度）。無ければ '--'
  final double? outBpm;
  final double? inBpm;

  /// 次曲のジョグ。null なら回せない（切り替わった後・拍の格子が無い）
  final ({double periodMs, double valueMs, double maxMs, double? errorMs})? jog;

  /// 次曲のテンポの微調整（±%）。null なら動かせない
  final ({double percent, double maxPercent})? tempo;

  final void Function(double valueMs, {required bool touching})? onJog;
  final ValueChanged<double>? onJogEnd;
  final ValueChanged<double>? onTempo;
  final ValueChanged<double>? onTempoEnd;

  /// 合わせた分（ジョグとテンポ）をまとめて曲に保存。何も動かしていなければ null
  final VoidCallback? onSave;

  /// ジョグとテンポを 0 に戻す。何も動かしていなければ null
  final VoidCallback? onReset;

  /// 次曲の円盤の直径の範囲。幅から決める（脇の狭い横画面は小さく、タブレットは大きく）
  static const maxDiscSize = 150.0;
  static const minDiscSize = 80.0;

  /// 前曲の盤は次曲の円盤に対してこの倍率（触れない脇役）
  static const subDiscRatio = 0.62;

  /// 前曲の列の薄さ
  static const subOpacity = 0.7;

  /// フェーダーの列の幅
  static const faderColumnWidth = 56.0;

  /// 板の下の 1 行（「−」「＋」・保存・戻す・線の切り替え）の高さ。常にある
  static const buttonsRowHeight = 36.0;

  static const _padding = AppSpacing.lg;
  static const _gap = AppSpacing.lg;

  /// 板の下端を、コントローラーの上端からどれだけ上に浮かせるか
  /// （コントローラーの板の上の余白 18px + 隙間）
  static const liftAbove = 26.0;

  /// 幅 [width] のときの次曲の円盤の直径
  static double discSizeFor(double width) =>
      ((width - _padding * 2 - _gap * 2 - faderColumnWidth) / (1 + subDiscRatio))
          .clamp(minDiscSize, maxDiscSize);

  /// 幅 [width] のときの前曲の盤の直径
  static double subDiscSizeFor(double width) =>
      discSizeFor(width) * subDiscRatio;

  /// 2 つのテンポが揃っているとみなす差（%）
  static const matchedPercent = 0.5;

  @override
  Widget build(BuildContext context) {
    final size = discSizeFor(width);
    final subSize = subDiscSizeFor(width);
    final jog = this.jog;
    final tempo = this.tempo;
    final outBpm = this.outBpm;
    final inBpm = this.inBpm;
    final matched = outBpm != null &&
        inBpm != null &&
        outBpm > 0 &&
        ((inBpm - outBpm) / outBpm).abs() * 100 < matchedPercent;

    final Widget inDisc = jog == null
        ? JogWheel.platter(turns: inTurns, title: '次曲', size: size)
        : JogWheel(
            periodMs: jog.periodMs,
            valueMs: jog.valueMs,
            maxMs: jog.maxMs,
            errorMs: jog.errorMs,
            size: size,
            onChanged: onJog ?? (_, {required bool touching}) {},
            onChangeEnd: onJogEnd ?? (_) {},
          );
    final parts = (
      out: Opacity(
        opacity: subOpacity,
        child: _column([
          JogWheel.platter(turns: outTurns, title: '前曲', size: subSize),
          _bpmLabel(context, outBpm, matched: false),
        ]),
      ),
      inCol: _column([
        inDisc,
        _bpmLabel(context, inBpm, matched: matched),
      ]),
      fader: SizedBox(
        width: faderColumnWidth,
        child: _column([
          PitchFader(
            percent: tempo?.percent ?? 0,
            maxPercent: tempo?.maxPercent ?? 8,
            // 溝の下端を円盤の下端に、値を BPM の行に揃える
            height: size,
            onChanged: tempo == null ? null : onTempo,
            onChangeEnd: tempo == null ? null : onTempoEnd,
          ),
        ]),
      ),
    );

    return SizedBox(
      width: width,
      child: GlassPanel(
        padding: const EdgeInsets.all(_padding),
        // 動画の上に置くので暗く敷く（読めることが優先）
        scrim: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdvanceStage<_DeckParts>(
              stageKey: contentKey ?? const ValueKey('deck'),
              value: parts,
              builder: (context, current, previous, phases) => _layout(
                current,
                previous,
                phases,
                size: size,
                subSize: subSize,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            _toolbar(context),
          ],
        ),
      ),
    );
  }

  /// 板の下の 1 行。常に同じ高さであって、押せないときは灰色になるだけ
  /// （消すと板の高さが変わって見た目がずれる）。組が進む演出の外なので動かない。
  /// 左 = 帯の窓「−」「＋」、真ん中 = 次曲の合わせの保存・戻す、右 = 線の表示切り替え
  Widget _toolbar(BuildContext context) {
    Widget button(IconData icon, String tooltip, VoidCallback? onTap,
            {Color? color}) =>
        IconButton(
          icon: Icon(icon, size: AppIconSizes.sm),
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          visualDensity: VisualDensity.compact,
          color: color,
          onPressed: onTap,
        );
    Widget toggle(IconData icon, String tooltip, bool on,
            ValueChanged<bool>? onChanged) =>
        button(
          icon,
          tooltip,
          onChanged == null ? null : () => onChanged(!on),
          color: on ? AppTheme.accentGreen : AppTheme.muted(context),
        );
    Widget group(List<Widget> children) =>
        Row(mainAxisSize: MainAxisSize.min, children: children);
    return SizedBox(
      height: buttonsRowHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          group([
            button(Icons.remove, '範囲を広げる', onWider),
            button(Icons.add, '範囲を狭める', onNarrower),
          ]),
          group([
            button(Icons.push_pin_outlined, '合わせた分をこの曲に保存', onSave,
                color: AppTheme.accentGreen),
            button(Icons.refresh, '真ん中に戻す', onReset),
          ]),
          group([
            toggle(Icons.ssid_chart, '音量の線', showCurves, onShowCurves),
            toggle(Icons.view_week_outlined, '拍の線', showBeats, onShowBeats),
          ]),
        ],
      ),
    );
  }

  /// 3 列を並べる。動いていないときは Row。組が進んでいる間は [AdvanceStage] の
  /// 3 拍子で、前曲の列は左へ抜け、次曲の列は左へ寄りながら前曲の大きさに縮んで
  /// 新しい前曲の列に溶け、新しい次曲の列は右から入る。フェーダーは新しい値に溶ける
  Widget _layout(
    _DeckParts current,
    _DeckParts? previous,
    AdvancePhases phases, {
    required double size,
    required double subSize,
  }) {
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        current.out,
        const SizedBox(width: _gap),
        current.inCol,
        const SizedBox(width: _gap),
        current.fader,
      ],
    );
    if (previous == null) return row;

    final leave = phases.leave;
    final rise = phases.rise;
    final enter = phases.enter;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final total = subSize + _gap + size + _gap + faderColumnWidth;
        final xOut = ((w - total) / 2).clamp(0.0, w);
        final xIn = xOut + subSize + _gap;
        final xFader = xIn + size + _gap;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // 大きさ取りのために今の並びを透明で置く（触れない）
            IgnorePointer(child: Opacity(opacity: 0, child: row)),
            // 1. 前曲の盤は左へ抜ける
            if (leave < 1)
              _place(
                left: xOut - (xOut + subSize) * leave,
                opacity: 1 - leave,
                child: previous.out,
              ),
            // 新しい前曲の盤（次曲が寄ってくるのに合わせて現れる）
            _place(left: xOut, opacity: rise, child: current.out),
            // 2. 次曲の円盤が左へ寄りながら縮む
            if (rise < 1)
              _place(
                left: xIn - (xIn - xOut) * rise,
                opacity: 1 - rise,
                child: Transform.scale(
                  scale: 1 - (1 - subDiscRatio) * rise,
                  alignment: Alignment.bottomLeft,
                  child: previous.inCol,
                ),
              ),
            // 3. 新しい次曲の円盤が右から入ってくる
            _place(
              left: xIn + (w - xIn) * (1 - enter),
              opacity: enter,
              child: current.inCol,
            ),
            // フェーダーは新しい次曲の値に溶ける
            if (rise < 1)
              _place(left: xFader, opacity: 1 - rise, child: previous.fader),
            _place(left: xFader, opacity: rise, child: current.fader),
          ],
        );
      },
    );
  }

  static Widget _place({
    required double left,
    required double opacity,
    required Widget child,
  }) =>
      Positioned(
        left: left,
        bottom: 0,
        child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
      );

  Widget _column(List<Widget> children) => Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      );

  Widget _bpmLabel(BuildContext context, double? bpm, {required bool matched}) {
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: matched ? AppTheme.accentGreen : AppTheme.muted(context),
        );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Text(bpm == null ? '-- BPM' : '${bpm.toStringAsFixed(1)} BPM',
          style: style),
    );
  }
}
