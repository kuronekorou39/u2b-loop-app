import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/musical_key.dart';
import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';
import '../providers/data_provider.dart';

/// テンポ/キーの手動補正シート。
/// 自動検出は BPM の倍/半分と長調/短調を取り違えることがあるので、ここで直す。
class TempoKeySheet extends ConsumerStatefulWidget {
  const TempoKeySheet({super.key, required this.item, required this.onReanalyze});

  final LoopItem item;
  final VoidCallback onReanalyze;

  static Future<void> show(
    BuildContext context, {
    required LoopItem item,
    required VoidCallback onReanalyze,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => TempoKeySheet(item: item, onReanalyze: onReanalyze),
    );
  }

  @override
  ConsumerState<TempoKeySheet> createState() => _TempoKeySheetState();
}

class _TempoKeySheetState extends ConsumerState<TempoKeySheet> {
  late final TextEditingController _bpmController;
  String? _key;

  @override
  void initState() {
    super.initState();
    final bpm = widget.item.bpm;
    _bpmController =
        TextEditingController(text: bpm == null ? '' : _format(bpm));
    _key = widget.item.musicalKey;
  }

  @override
  void dispose() {
    _bpmController.dispose();
    super.dispose();
  }

  static String _format(double bpm) =>
      bpm == bpm.roundToDouble() ? bpm.round().toString() : bpm.toStringAsFixed(1);

  double? get _bpm => double.tryParse(_bpmController.text.trim());

  void _scaleBpm(double factor) {
    final bpm = _bpm;
    if (bpm == null) return;
    _bpmController.text = _format(bpm * factor);
    setState(() {});
  }

  Future<void> _save() async {
    final bpm = _bpm;
    if (_bpmController.text.trim().isNotEmpty && (bpm == null || bpm <= 0)) {
      return;
    }
    await ref.read(loopItemsProvider.notifier).saveAnalysis(
          widget.item.id,
          bpm: bpm,
          musicalKey: _key,
          markAnalyzed: false,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bpmController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'BPM',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              OutlinedButton(
                onPressed: _bpm == null ? null : () => _scaleBpm(0.5),
                child: const Text('÷2'),
              ),
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton(
                onPressed: _bpm == null ? null : () => _scaleBpm(2),
                child: const Text('×2'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          DropdownButtonFormField<String?>(
            initialValue: _key,
            decoration: const InputDecoration(
              labelText: 'キー',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('未設定')),
              for (final k in MusicalKey.allKeys)
                DropdownMenuItem<String?>(
                    value: k, child: Text(MusicalKey.display(k)!)),
            ],
            onChanged: (v) => setState(() => _key = v),
          ),
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
              FilledButton(onPressed: _save, child: const Text('保存')),
            ],
          ),
        ],
      ),
    );
  }
}
