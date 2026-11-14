import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/app_version.dart';
import 'package:u2b_loop_app/services/update_service.dart';

Map<String, dynamic> release(String tag,
        {bool prerelease = false, bool draft = false, bool apk = true}) =>
    {
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': draft,
      'assets': [
        if (apk)
          {'name': 'u2b-loop-$tag.apk', 'browser_download_url': 'https://x/$tag'},
      ],
    };

void main() {
  AppVersion v(String s) => AppVersion.tryParse(s)!;

  test('バージョンの並び: テスト版は同じ数字の通常版より前', () {
    final sorted = ['1.158.0', '1.157.0', '1.158.0-beta.2', '1.158.0-beta.10', 'v1.158.0-beta.1']
        .map(v)
        .toList()
      ..sort();
    expect(sorted.map((e) => '${e.core.join('.')}/${e.pre}'), [
      '1.157.0/null', '1.158.0/1', '1.158.0/2', '1.158.0/10', '1.158.0/null',
    ]);
    expect(AppVersion.tryParse('abc'), isNull);
    expect(AppVersion.tryParse('1.2'), isNull);
  });

  final releases = [
    release('v1.158.0-beta.2', prerelease: true),
    release('v1.158.0-beta.1', prerelease: true),
    release('v1.157.0'),
    release('v1.156.0'),
  ];

  test('ふつうの端末にはテスト版を知らせない', () {
    expect(UpdateService.pickUpdate(releases, v('1.157.0'), includeBeta: false),
        isNull);
    expect(
        UpdateService.pickUpdate(releases, v('1.156.0'), includeBeta: false)?.tag,
        '1.157.0');
  });

  test('テスト版を受け取る端末には一番新しいテスト版', () {
    final offer =
        UpdateService.pickUpdate(releases, v('1.157.0'), includeBeta: true);
    expect(offer?.tag, '1.158.0-beta.2');
    expect(offer?.apkUrl, 'https://x/v1.158.0-beta.2');
    expect(UpdateService.pickUpdate(releases, v('1.158.0-beta.2'), includeBeta: true),
        isNull);
  });

  test('テスト版を入れた端末に、同じ数字の通常版が出たら知らせる', () {
    final all = [release('v1.158.0'), ...releases];
    for (final beta in [true, false]) {
      expect(
          UpdateService.pickUpdate(all, v('1.158.0-beta.2'), includeBeta: beta)?.tag,
          '1.158.0');
    }
  });

  test('下書き・APK の無い版は選ばない', () {
    final all = [
      release('v1.160.0', draft: true),
      release('v1.159.0', apk: false),
      ...releases,
    ];
    expect(UpdateService.pickUpdate(all, v('1.156.0'), includeBeta: false)?.tag,
        '1.157.0');
  });
}
