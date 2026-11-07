import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/loudness.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/providers/player_provider.dart';

/// ユーザーの音量: 0〜200%、保存する、100% の前後は 100 に吸い付く
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Hive.init(null);
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());
  setUp(() => AppBoxes.settings.clear());

  test('既定は 100。200 まで上げられ、それより上は 200', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(userVolumeProvider), 100);
    c.read(userVolumeProvider.notifier).value = 160;
    expect(c.read(userVolumeProvider), 160);
    c.read(userVolumeProvider.notifier).value = 250;
    expect(c.read(userVolumeProvider), Loudness.maxVolume);
  });

  test('100 の前後は 100 に吸い付く', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(userVolumeProvider.notifier).value = 102.5;
    expect(c.read(userVolumeProvider), 100);
    c.read(userVolumeProvider.notifier).value = 96;
    expect(c.read(userVolumeProvider), 96);
  });

  test('起動し直しても残る。ミュートのまま終わったら 100 で始める', () {
    final a = ProviderContainer();
    a.read(userVolumeProvider.notifier).value = 140;
    a.dispose();
    final b = ProviderContainer();
    expect(b.read(userVolumeProvider), 140);
    b.read(userVolumeProvider.notifier).value = 0;
    b.dispose();
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(userVolumeProvider), 100);
  });
}
