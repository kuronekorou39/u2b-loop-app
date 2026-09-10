import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/loading_animations/loading_animation.dart';
import '../core/storage/app_boxes.dart';

/// ローディングアニメーション設定。null = ランダム。
final loadingAnimationProvider =
    StateNotifierProvider<LoadingAnimationNotifier, LoadingAnimationType?>(
        (ref) => LoadingAnimationNotifier());

class LoadingAnimationNotifier extends StateNotifier<LoadingAnimationType?> {
  LoadingAnimationNotifier() : super(null) {
    _load();
  }

  static const _key = SettingsKeys.loadingAnimation;

  void _load() {
    final box = AppBoxes.settings;
    final saved = box.get(_key) as String?;
    if (saved == null) {
      state = null; // ランダム
    } else {
      state = LoadingAnimationType.values
          .where((e) => e.name == saved)
          .firstOrNull;
    }
  }

  void set(LoadingAnimationType? type) {
    state = type;
    final box = AppBoxes.settings;
    if (type == null) {
      box.delete(_key);
    } else {
      box.put(_key, type.name);
    }
  }
}

/// パフォーマンスオーバーレイ設定
final perfOverlayProvider =
    StateNotifierProvider<PerfOverlayNotifier, bool>(
        (ref) => PerfOverlayNotifier());

class PerfOverlayNotifier extends StateNotifier<bool> {
  PerfOverlayNotifier() : super(false) {
    state = AppBoxes.settings.get(SettingsKeys.perfOverlay, defaultValue: false) as bool;
  }

  void toggle() {
    state = !state;
    AppBoxes.settings.put(SettingsKeys.perfOverlay, state);
  }
}
