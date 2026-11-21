import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import 'persisted_setting.dart';

/// ダークテーマか（既定はダーク）
final themeProvider = StateNotifierProvider<PersistedBool, bool>(
    (ref) => PersistedBool(SettingsKeys.darkMode, true));
