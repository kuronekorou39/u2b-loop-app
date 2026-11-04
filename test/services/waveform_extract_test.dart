import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/native_channels.dart';
import 'package:u2b_loop_app/services/waveform_service.dart';

/// ネイティブの波形デコードは同時に 1 つ。順に頼み、中止されたら失敗扱いにしない
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> started;
  late List<Completer<Object?>> pending;
  setUp(() {
    started = [];
    pending = [];
    messenger.setMockMethodCallHandler(NativeChannels.waveform, (call) async {
      switch (call.method) {
        case 'extractAmplitudes':
          started.add((call.arguments as Map)['url'] as String);
          final c = Completer<Object?>();
          pending.add(c);
          return c.future;
        case 'cancelExtraction':
          // ネイティブは今のデコードを止めて「中止した」と返す
          for (final c in pending) {
            if (!c.isCompleted) c.complete({'cancelled': true});
          }
          return null;
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(NativeChannels.waveform, null));

  test('2 つ頼んでも 1 つずつ順に（後のが前のを中止させない）', () async {
    final service = WaveformService();
    final a = service.generateFromUrl('/a', 10);
    final b = service.generateFromUrl('/b', 10);
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/a'], reason: '前のが終わるまで次は頼まない');
    pending[0].complete(List<int>.filled(100, 50));
    expect(await a, isNotNull);
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/a', '/b']);
    pending[1].complete(List<int>.filled(100, 50));
    expect(await b, isNotNull);
  });

  test('中止されたら WaveformCancelled（粗い波形に切り替えない）', () async {
    final service = WaveformService();
    final a = service.generateForLocalFile('/does/not/exist.m4a', 10);
    final expectation = expectLater(a, throwsA(isA<WaveformCancelled>()));
    await Future<void>.delayed(Duration.zero);
    await service.cancel();
    await expectation;
  });
}
