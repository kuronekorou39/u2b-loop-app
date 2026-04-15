import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

final themeProvider =
    StateNotifierProvider<ThemeNotifier, bool>((ref) => ThemeNotifier());

class ThemeNotifier extends StateNotifier<bool> {
  static const _key = 'dark_mode';

  ThemeNotifier() : super(true) {
    state = Hive.box('settings').get(_key, defaultValue: true) as bool;
  }

  void toggle() {
    state = !state;
    Hive.box('settings').put(_key, state);
  }

  set value(bool v) {
    state = v;
    Hive.box('settings').put(_key, v);
  }
}
