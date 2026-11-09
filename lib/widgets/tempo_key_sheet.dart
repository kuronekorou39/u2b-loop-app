import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/key_sections.dart';
import '../core/audio/musical_key.dart';
import '../core/audio/tempo_sections.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_sheets.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../providers/data_provider.dart';

/// テンポ/キーの手動補正シート。
/// 自動検出は BPM の倍/半分と長調/短調を取り違えることがあるので、ここで直す。
/// テンポが変わる曲・転調する曲は、区切りごとに値を直せる（区切りの位置はそのまま）
class TempoKeySheet extends ConsumerStatefulWidget {
  const TempoKeySheet({super.key, required this.item, required this.onReanalyze});

  final LoopItem item;
  final VoidCallback onReanalyze;

  static Future<void> show(
    BuildContext context, {
    required LoopItem item,
    required VoidCallback onReanalyze,
  }) {
    return AppSheets.show<void>(
      context,
      builder: (_) => TempoKeySheet(item: item, onReanalyze: onReanalyze),
    );
  }

  @override
  ConsumerState<TempoKeySheet> createState() => _TempoKeySheetState();
}

class _TempoKeySheetState extends ConsumerState<TempoKeySheet> {
  /// テンポの欄。区切りが無ければ 1 つ（曲の BPM）、あれば区切りごと
  late final List<TextEditingController> _bpmControllers;
  late final List<TempoSection> _tempoSections = widget.item.tempoSections;
  late final int _mainTempo = widget.item.mainTempoSectionIndex ?? 0;

  /// キー。区切りが無ければ 1 つ、あれば区切りごと
  late final List<KeySection> _keySections = widget.item.keySections;
  late final List<String?> _keys;

  bool get _tempoSplit => _tempoSections.length >= 2;
  bool get _keySplit => _keySections.length >= 2;

  @override
  void initState() {
    super.initState();
    _bpmControllers = _tempoSplit
        ? [for (final s in _tempoSections) TextEditingController(text: _format(s.bpm))]
        : [
            TextEditingController(
                text: widget.item.bpm == null ? '' : _format(widget.item.bpm!)),
          ];
    _keys = _keySplit
        ? [for (final s in _keySections) s.key]
        : [widget.item.musicalKey];
  }

  @override
  void dispose() {
    for (final c in _bpmControllers) {
      c.dispose();
    }
    super.dispose();
  }

  static String _format(double bpm) =>
      bpm == bpm.roundToDouble() ? bpm.round().toString() : bpm.toStringAsFixed(1);

  double? _bpmAt(int i) => double.tryParse(_bpmControllers[i].text.trim());

  /// 入力があるのに数字として読めない / 0 以下ならエラー文。
  /// 区切りの欄は空欄にできない（1 つの BPM なら空欄 = 未設定）
  String? _bpmError(int i) {
    final text = _bpmControllers[i].text.trim();
    if (text.isEmpty) return _tempoSplit ? '数字を入れてください' : null;
    final bpm = _bpmAt(i);
    if (bpm == null || bpm <= 0) return '1 以上の数字を入れてください';
    return null;
  }

  bool get _valid =>
      [for (var i = 0; i < _bpmControllers.length; i++) _bpmError(i)].every((e) => e == null);

  /// ×2 / ÷2 は全部の欄にまとめて
  void _scaleBpm(double factor) {
    for (var i = 0; i < _bpmControllers.length; i++) {
      final bpm = _bpmAt(i);
      if (bpm != null) _bpmControllers[i].text = _format(bpm * factor);
    }
    setState(() {});
  }

  Future<void> _save() async {
    if (!_valid) return;
    await ref.read(loopItemsProvider.notifier).editTempoKey(
          widget.item.id,
          bpm: _tempoSplit ? _bpmAt(_mainTempo) : _bpmAt(0),
          key: _keySplit ? null : _keys.first,
          tempo: _tempoSplit
              ? [
                  for (var i = 0; i < _tempoSections.length; i++)
                    TempoSection(_tempoSections[i].startMs, _bpmAt(i)!),
                ]
              : null,
          keys: _keySplit
              ? [
                  for (var i = 0; i < _keySections.length; i++)
                    KeySection(_keySections[i].startMs, _keys[i] ?? _keySections[i].key),
                ]
              : null,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // キーボードと、下に浮いているミニプレイヤー（viewPadding に入っている）の両方をよける。
    // 横画面でキーボードが出ても溢れないよう中はスクロール
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.viewPaddingOf(context).bottom;
    final anyBpm = [for (var i = 0; i < _bpmControllers.length; i++) _bpmAt(i)]
        .any((b) => b != null);
    final scaleButtons = [
      OutlinedButton(
        onPressed: anyBpm ? () => _scaleBpm(0.5) : null,
        child: const Text('÷2'),
      ),
      const SizedBox(width: AppSpacing.sm),
      OutlinedButton(
        onPressed: anyBpm ? () => _scaleBpm(2) : null,
        child: const Text('×2'),
      ),
    ];
    return SafeArea(
      top: false,
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xl + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('テンポ / キー', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '自動検出は倍/半分のテンポや、長調/短調を取り違えることがあります。',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (!_tempoSplit)
              Row(
                children: [
                  Expanded(child: _bpmField(0, label: 'BPM', hint: '空欄で未設定')),
                  const SizedBox(width: AppSpacing.md),
                  ...scaleButtons,
                ],
              )
            else ...[
              Row(
                children: [
                  Expanded(child: Text('テンポの区切り', style: textTheme.labelLarge)),
                  ...scaleButtons,
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              for (var i = 0; i < _tempoSections.length; i++)
                _sectionRow(
                  _tempoSections[i].startMs,
                  main: i == _mainTempo,
                  child: _bpmField(i, label: 'BPM'),
                ),
            ],
            const SizedBox(height: AppSpacing.lg),
            if (!_keySplit)
              _keyField(0, label: 'キー', allowUnset: true)
            else ...[
              Text('キーの区切り', style: textTheme.labelLarge),
              const SizedBox(height: AppSpacing.sm),
              for (var i = 0; i < _keySections.length; i++)
                _sectionRow(_keySections[i].startMs,
                    child: _keyField(i, label: 'キー')),
            ],
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onReanalyze();
                  },
                  icon: const Icon(Icons.refresh, size: AppIconSizes.sm),
                  label: const Text('再解析'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('キャンセル'),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                    onPressed: _valid ? _save : null, child: const Text('保存')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 区切り 1 行: 左に始まりの時刻（一番長い区切りには「メイン」）、右に欄
  Widget _sectionRow(int startMs, {bool main = false, required Widget child}) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(TimeUtils.formatShortMs(startMs),
                    style: textTheme.bodyMedium
                        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                if (main)
                  Text('メイン',
                      style: textTheme.labelSmall
                          ?.copyWith(color: AppTheme.accentGreen)),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _bpmField(int i, {required String label, String? hint}) => TextField(
        controller: _bpmControllers[i],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: _bpmError(i),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      );

  Widget _keyField(int i, {required String label, bool allowUnset = false}) =>
      DropdownButtonFormField<String?>(
        initialValue: _keys[i],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          if (allowUnset)
            const DropdownMenuItem<String?>(value: null, child: Text('未設定')),
          for (final k in MusicalKey.allKeys)
            DropdownMenuItem<String?>(value: k, child: Text(MusicalKey.display(k)!)),
        ],
        onChanged: (v) => setState(() => _keys[i] = v),
      );
}
