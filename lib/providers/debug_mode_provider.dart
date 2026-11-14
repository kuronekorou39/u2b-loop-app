import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import 'perf_overlay_provider.dart';

/// デバッグモード（設定のバージョン行を 5 回タップで出す）。
/// オンの間だけ、詳細設定に「デバッグ」の群（テスト版の受け取り・計測・ログなど、
/// ふつうの人が触らないもの）が出る
final debugModeProvider =
    StateNotifierProvider<DebugModeNotifier, bool>((ref) => DebugModeNotifier(ref));

class DebugModeNotifier extends StateNotifier<bool> {
  DebugModeNotifier(this._ref)
      : super(AppBoxes.settings.get(SettingsKeys.debugMode, defaultValue: false)
            as bool);

  final Ref _ref;

  void enable() {
    state = true;
    AppBoxes.settings.put(SettingsKeys.debugMode, true);
  }

  /// 終了。中の設定は見えなくなるので、効いたまま残らないよう一緒に切る
  void disable() {
    state = false;
    AppBoxes.settings.put(SettingsKeys.debugMode, false);
    _ref.read(betaUpdatesProvider.notifier).value = false;
    if (_ref.read(perfOverlayProvider)) {
      _ref.read(perfOverlayProvider.notifier).toggle();
    }
  }
}

/// テスト版（GitHub のプレリリース）も更新として受け取る。読むのは UpdateService
final betaUpdatesProvider =
    StateNotifierProvider<BetaUpdatesNotifier, bool>((ref) => BetaUpdatesNotifier());

class BetaUpdatesNotifier extends StateNotifier<bool> {
  BetaUpdatesNotifier()
      : super(AppBoxes.settings.get(SettingsKeys.betaUpdates, defaultValue: false)
            as bool);

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(SettingsKeys.betaUpdates, v);
  }
}
