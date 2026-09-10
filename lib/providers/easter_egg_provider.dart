import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/storage/app_boxes.dart';

class EasterEggState {
  final bool statsUnlocked;
  final bool cassetteUnlocked;
  final bool matrixUnlocked;

  const EasterEggState({
    this.statsUnlocked = false,
    this.cassetteUnlocked = false,
    this.matrixUnlocked = false,
  });

  int get unlockedCount =>
      (statsUnlocked ? 1 : 0) +
      (cassetteUnlocked ? 1 : 0) +
      (matrixUnlocked ? 1 : 0);
}

final easterEggProvider =
    StateNotifierProvider<EasterEggNotifier, EasterEggState>(
        (ref) => EasterEggNotifier());

class EasterEggNotifier extends StateNotifier<EasterEggState> {
  EasterEggNotifier() : super(const EasterEggState()) {
    _load();
  }

  void _load() {
    final box = AppBoxes.settings;
    state = EasterEggState(
      statsUnlocked: box.get(SettingsKeys.eeStats, defaultValue: false) as bool,
      cassetteUnlocked: box.get(SettingsKeys.eeCassette, defaultValue: false) as bool,
      matrixUnlocked: box.get(SettingsKeys.eeMatrix, defaultValue: false) as bool,
    );
  }

  bool unlockStats() {
    if (state.statsUnlocked) return false;
    state = EasterEggState(
      statsUnlocked: true,
      cassetteUnlocked: state.cassetteUnlocked,
      matrixUnlocked: state.matrixUnlocked,
    );
    AppBoxes.settings.put(SettingsKeys.eeStats, true);
    return true;
  }

  bool unlockCassette() {
    if (state.cassetteUnlocked) return false;
    state = EasterEggState(
      statsUnlocked: state.statsUnlocked,
      cassetteUnlocked: true,
      matrixUnlocked: state.matrixUnlocked,
    );
    AppBoxes.settings.put(SettingsKeys.eeCassette, true);
    return true;
  }

  bool unlockMatrix() {
    if (state.matrixUnlocked) return false;
    state = EasterEggState(
      statsUnlocked: state.statsUnlocked,
      cassetteUnlocked: state.cassetteUnlocked,
      matrixUnlocked: true,
    );
    AppBoxes.settings.put(SettingsKeys.eeMatrix, true);
    return true;
  }
}
