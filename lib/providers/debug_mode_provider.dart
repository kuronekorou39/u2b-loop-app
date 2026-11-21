import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import 'perf_overlay_provider.dart';
import 'persisted_setting.dart';

/// デバッグモード（設定の下の「v… · 更新を確認」を 5 回タップで出す）。
/// オンの間だけ、設定のトップに「デバッグ」のボタン（テスト版の受け取り・計測・ログなど、
/// ふつうの人が触らないもの）が出る
final debugModeProvider =
    StateNotifierProvider<DebugModeNotifier, bool>((ref) => DebugModeNotifier(ref));

class DebugModeNotifier extends PersistedSetting<bool> {
  DebugModeNotifier(this._ref) : super(SettingsKeys.debugMode, false);

  final Ref _ref;

  void enable() => value = true;

  /// 終了。中の設定は見えなくなるので、効いたまま残らないよう一緒に切る
  void disable() {
    value = false;
    _ref.read(betaUpdatesProvider.notifier).value = false;
    if (_ref.read(perfOverlayProvider)) {
      _ref.read(perfOverlayProvider.notifier).toggle();
    }
  }
}

/// テスト版（GitHub のプレリリース）も更新として受け取る。読むのは UpdateService
final betaUpdatesProvider = StateNotifierProvider<PersistedBool, bool>(
    (ref) => PersistedBool(SettingsKeys.betaUpdates, false));
