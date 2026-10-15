import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/storage/app_boxes.dart';

/// パフォーマンスオーバーレイ（FPS・描画負荷）の表示設定。詳細設定 > 開発者向け
final perfOverlayProvider =
    StateNotifierProvider<PerfOverlayNotifier, bool>(
        (ref) => PerfOverlayNotifier());

class PerfOverlayNotifier extends StateNotifier<bool> {
  PerfOverlayNotifier() : super(false) {
    state = AppBoxes.settings.get(SettingsKeys.perfOverlay, defaultValue: false)
        as bool;
  }

  void toggle() {
    state = !state;
    AppBoxes.settings.put(SettingsKeys.perfOverlay, state);
  }
}
