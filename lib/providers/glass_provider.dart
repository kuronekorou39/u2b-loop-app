import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';

/// 再生画面のガラス板で背景をぼかすか。
/// ぼかしは GPU 負荷があるので、重い端末では切れるようにしてある（既定はオン）。
final glassBlurProvider =
    StateNotifierProvider<GlassBlurNotifier, bool>((ref) => GlassBlurNotifier());

class GlassBlurNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.glassBlur;

  GlassBlurNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}
