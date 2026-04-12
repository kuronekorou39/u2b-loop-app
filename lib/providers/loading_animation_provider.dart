import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../widgets/loading_animations/loading_animation.dart';

/// ローディングアニメーション設定。null = ランダム。
final loadingAnimationProvider =
    StateNotifierProvider<LoadingAnimationNotifier, LoadingAnimationType?>(
        (ref) => LoadingAnimationNotifier());

class LoadingAnimationNotifier extends StateNotifier<LoadingAnimationType?> {
  LoadingAnimationNotifier() : super(null) {
    _load();
  }

  static const _key = 'loading_animation';

  void _load() {
    final box = Hive.box('settings');
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
    final box = Hive.box('settings');
    if (type == null) {
      box.delete(_key);
    } else {
      box.put(_key, type.name);
    }
  }
}
