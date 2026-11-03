import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';

/// 再生画面のガラス板で背景をぼかすか。
/// ぼかしは GPU 負荷があるので、重い端末では切れるようにしてある（既定はオン）。
final glassBlurProvider =
    StateNotifierProvider<GlassBlurNotifier, bool>((ref) => GlassBlurNotifier());

/// タグ一覧にサムネを出すか（既定はオン）
final tagThumbsProvider = StateNotifierProvider<BoolSettingNotifier, bool>(
    (ref) => BoolSettingNotifier(SettingsKeys.tagThumbs, defaultValue: true));

/// 設定 box の真偽値 1 つ
class BoolSettingNotifier extends StateNotifier<bool> {
  BoolSettingNotifier(this._key, {required bool defaultValue}) : super(defaultValue) {
    state = AppBoxes.settings.get(_key, defaultValue: defaultValue) as bool;
  }

  final String _key;

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}

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
