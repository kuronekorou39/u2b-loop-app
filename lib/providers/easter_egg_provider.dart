import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/storage/app_boxes.dart';

/// 隠しステータス（設定のバージョン行を 5 回タップで解放）。
/// 以前は読み込み画面の隠しアニメーション（カセット・マトリックス）もあったが、
/// 読み込み画面ごと v1.92.0 で廃止した
class EasterEggState {
  final bool statsUnlocked;

  const EasterEggState({this.statsUnlocked = false});
}

final easterEggProvider =
    StateNotifierProvider<EasterEggNotifier, EasterEggState>(
        (ref) => EasterEggNotifier());

class EasterEggNotifier extends StateNotifier<EasterEggState> {
  EasterEggNotifier() : super(const EasterEggState()) {
    state = EasterEggState(
      statsUnlocked:
          AppBoxes.settings.get(SettingsKeys.eeStats, defaultValue: false) as bool,
    );
  }

  bool unlockStats() {
    if (state.statsUnlocked) return false;
    state = const EasterEggState(statsUnlocked: true);
    AppBoxes.settings.put(SettingsKeys.eeStats, true);
    return true;
  }
}
