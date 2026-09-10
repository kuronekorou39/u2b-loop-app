import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/storage/app_boxes.dart';

final themeProvider =
    StateNotifierProvider<ThemeNotifier, bool>((ref) => ThemeNotifier());

class ThemeNotifier extends StateNotifier<bool> {
  static const _key = SettingsKeys.darkMode;

  ThemeNotifier() : super(true) {
    state = AppBoxes.settings.get(_key, defaultValue: true) as bool;
  }

  void toggle() {
    state = !state;
    AppBoxes.settings.put(_key, state);
  }

  set value(bool v) {
    state = v;
    AppBoxes.settings.put(_key, v);
  }
}
