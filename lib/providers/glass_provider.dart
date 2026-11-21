import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import 'persisted_setting.dart';

/// 再生画面のガラス板で背景をぼかすか（設定「すりガラス効果」）。
/// ぼかしは GPU 負荷があるので、重い端末では切れるようにしてある（既定はオン）。
final glassBlurProvider = StateNotifierProvider<PersistedBool, bool>(
    (ref) => PersistedBool(SettingsKeys.glassBlur, true));

/// タグ一覧にサムネを出すか（既定はオン）
final tagThumbsProvider = StateNotifierProvider<PersistedBool, bool>(
    (ref) => PersistedBool(SettingsKeys.tagThumbs, true));
