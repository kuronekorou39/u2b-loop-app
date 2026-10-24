import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../glass_panel.dart';
import 'jog_wheel.dart';
import 'pitch_fader.dart';

/// デッキの板。重ね表示の間、コントローラーの上に浮かせて出す（動画や曲名に被さってよい。
/// 出しているときはこれがメイン）。帯には重ねない（波形が見えなくなり、操作もかぶる）。
///
/// 左から DJ 機材と同じ並び:
/// - 前曲の盤: 再生に合わせて回るだけ（鳴っている曲は動かさない）
/// - 次曲のジョグ（[JogWheel]）: 回して拍の位置（位相）を合わせる。BPM の下にピン = 保存、戻す
/// - 次曲のピッチフェーダー（[PitchFader]）: 拍の間隔（テンポ）を合わせる。
///   下に ×2 / ÷2（解析の BPM の倍/半分の取り違えを直す）
///
/// 各円盤の下にそのデッキのテンポ（BPM × 速度）。2 つが揃うと次曲側が緑。
/// 切り替わった後は次曲側も回る・見るだけ（[jog] / [tempo] が null）。
/// 値はすべて親が持ち、この板は見せて返すだけ
class MixDeck extends StatelessWidget {
  const MixDeck({
    super.key,
    required this.width,
    required this.outTurns,
    required this.inTurns,
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
    this.onDouble,
    this.onHalve,
  });

  /// 板の幅（コントローラーの幅に合わせる）
  final double width;

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

  /// BPM を倍 / 半分に。格子が無ければ null
  final VoidCallback? onDouble;
  final VoidCallback? onHalve;

  /// 円盤の直径の範囲。幅から決める（脇の狭い横画面は小さく、タブレットは大きく）
  static const maxDiscSize = 150.0;
  static const minDiscSize = 80.0;

  /// フェーダーの列の幅（フェーダー + 下の ×2 / ÷2）
  static const faderColumnWidth = 72.0;

  static const _padding = AppSpacing.lg;
  static const _gap = AppSpacing.lg;

  /// 板の下端を、コントローラーの上端からどれだけ上に浮かせるか
  /// （コントローラーの板の上の余白 18px + 隙間）
  static const liftAbove = 26.0;

  /// 幅 [width] のときの円盤の直径
  static double discSizeFor(double width) =>
      ((width - _padding * 2 - _gap * 2 - faderColumnWidth) / 2)
          .clamp(minDiscSize, maxDiscSize);

  /// 2 つのテンポが揃っているとみなす差（%）
  static const matchedPercent = 0.5;

  @override
  Widget build(BuildContext context) {
    final size = discSizeFor(width);
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
    // 保存・戻すは次曲の BPM の下（合わせられるときだけ）
    final Widget? inButtons = jog == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.push_pin_outlined, size: AppIconSizes.sm),
                tooltip: '合わせた分をこの曲に保存',
                visualDensity: VisualDensity.compact,
                color: AppTheme.accentGreen,
                onPressed: onSave,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: AppIconSizes.sm),
                tooltip: '真ん中に戻す',
                visualDensity: VisualDensity.compact,
                onPressed: onReset,
              ),
            ],
          );

    return SizedBox(
      width: width,
      child: GlassPanel(
        padding: const EdgeInsets.all(_padding),
        // 動画の上に置くので暗く敷く（読めることが優先）
        scrim: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.92),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _deck(
              context,
              JogWheel.platter(turns: outTurns, title: '前曲', size: size),
              _bpmLabel(context, outBpm, matched: false),
            ),
            const SizedBox(width: _gap),
            _deck(context, inDisc, _bpmLabel(context, inBpm, matched: matched),
                inButtons),
            const SizedBox(width: _gap),
            SizedBox(
              width: faderColumnWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PitchFader(
                    percent: tempo?.percent ?? 0,
                    maxPercent: tempo?.maxPercent ?? 8,
                    // ラベル 1 行ぶんを引いて、円盤と下端を揃える
                    height: size - 20,
                    onChanged: tempo == null ? null : onTempo,
                    onChangeEnd: tempo == null ? null : onTempoEnd,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _smallButton(context, '×2', '次曲の BPM を倍に', onDouble),
                      _smallButton(context, '÷2', '次曲の BPM を半分に', onHalve),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deck(BuildContext context, Widget disc, Widget label,
          [Widget? buttons]) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [disc, label, ?buttons],
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

  Widget _smallButton(
          BuildContext context, String text, String tooltip, VoidCallback? onTap) =>
      Tooltip(
        message: tooltip,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(32, 32),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(text, style: Theme.of(context).textTheme.labelSmall),
        ),
      );
}
