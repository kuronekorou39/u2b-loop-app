import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/persisted_setting.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';

/// 設定 box に保存する設定（PersistedSetting）: 保存が無ければ既定値、あれば読み、
/// 入れると保存する。enum は名前で保存。前の版からの移し替え・値の丸めは継いだクラスで
void main() {
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());
  setUp(() => AppBoxes.settings.clear());

  test('保存が無ければ既定値。入れると保存し、次に作ったときはその値', () {
    final a = PersistedBool(SettingsKeys.autoMix, true);
    expect(a.state, isTrue);
    expect(a.isSaved, isFalse);
    a.value = false;
    expect(a.state, isFalse);
    expect(AppBoxes.settings.get(SettingsKeys.autoMix), false);
    expect(PersistedBool(SettingsKeys.autoMix, true).state, isFalse);
  });

  test('オンオフは toggle で入れ替えて保存', () {
    final a = PersistedBool(SettingsKeys.darkMode, true)..toggle();
    expect(a.state, isFalse);
    expect(AppBoxes.settings.get(SettingsKeys.darkMode), false);
  });

  test('enum は名前で保存し、知らない名前は既定値に戻す', () {
    PersistedEnum(SettingsKeys.crossfadeCurve, CrossfadeCurve.defaultCurve,
            fromName: CrossfadeCurve.fromName)
        .value = CrossfadeCurve.nextFirst;
    expect(AppBoxes.settings.get(SettingsKeys.crossfadeCurve), 'nextFirst');
    expect(
        PersistedEnum(SettingsKeys.crossfadeCurve, CrossfadeCurve.defaultCurve,
                fromName: CrossfadeCurve.fromName)
            .state,
        CrossfadeCurve.nextFirst);
    AppBoxes.settings.put(SettingsKeys.crossfadeCurve, 'もう無い曲線');
    expect(
        PersistedEnum(SettingsKeys.crossfadeCurve, CrossfadeCurve.defaultCurve,
                fromName: CrossfadeCurve.fromName)
            .state,
        CrossfadeCurve.defaultCurve);
  });

  test('クロスフェード: 拍の設定が無ければ v1.94 までの秒数設定から移す', () {
    expect(CrossfadeNotifier().state, 0, reason: 'どちらも無ければオフ');
    AppBoxes.settings.put(SettingsKeys.crossfadeSeconds, 4);
    expect(CrossfadeNotifier().state, CrossfadeNotifier.migratedBeats);
    AppBoxes.settings.put(SettingsKeys.crossfadeBeats, 16);
    expect(CrossfadeNotifier().state, 16, reason: '拍の設定があればそれ');
  });

  test('効果音のタイミングは ±200ms に収めて保存', () {
    final n = SfxOffsetNotifier()..value = 999;
    expect(n.state, SfxOffsetNotifier.maxAbsMs);
    expect(AppBoxes.settings.get(SettingsKeys.sfxOffsetMs), SfxOffsetNotifier.maxAbsMs);
    n.nudge(-SfxOffsetNotifier.step);
    expect(n.state, SfxOffsetNotifier.maxAbsMs - SfxOffsetNotifier.step);
  });

  test('音量: 100% の近くは 100 に吸い付き、ミュートのまま終わっても次は鳴らす', () {
    final v = UserVolumeNotifier()..value = 102;
    expect(v.state, 100);
    v.value = 0;
    expect(AppBoxes.settings.get(SettingsKeys.userVolume), 0);
    expect(UserVolumeNotifier().state, 100);
    v.value = 150;
    expect(UserVolumeNotifier().state, 150);
  });
}
