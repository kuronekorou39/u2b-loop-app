import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
    final box = Hive.box('settings');
    state = EasterEggState(
      statsUnlocked: box.get('ee_stats', defaultValue: false) as bool,
      cassetteUnlocked: box.get('ee_cassette', defaultValue: false) as bool,
      matrixUnlocked: box.get('ee_matrix', defaultValue: false) as bool,
    );
  }

  bool unlockStats() {
    if (state.statsUnlocked) return false;
    state = EasterEggState(
      statsUnlocked: true,
      cassetteUnlocked: state.cassetteUnlocked,
      matrixUnlocked: state.matrixUnlocked,
    );
    Hive.box('settings').put('ee_stats', true);
    return true;
  }

  bool unlockCassette() {
    if (state.cassetteUnlocked) return false;
    state = EasterEggState(
      statsUnlocked: state.statsUnlocked,
      cassetteUnlocked: true,
      matrixUnlocked: state.matrixUnlocked,
    );
    Hive.box('settings').put('ee_cassette', true);
    return true;
  }

  bool unlockMatrix() {
    if (state.matrixUnlocked) return false;
    state = EasterEggState(
      statsUnlocked: state.statsUnlocked,
      cassetteUnlocked: state.cassetteUnlocked,
      matrixUnlocked: true,
    );
    Hive.box('settings').put('ee_matrix', true);
    return true;
  }
}
