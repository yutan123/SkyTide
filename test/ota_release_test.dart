import 'package:flutter_test/flutter_test.dart';
import 'package:skytide/ota_release.dart';

void main() {
  Map<String, dynamic> release({
    required String tag,
    bool draft = false,
    bool prerelease = false,
    List<Map<String, String>> assets = const [
      {
        'name': 'SkyTide.apk',
        'browser_download_url': 'https://example.com/SkyTide.apk',
      },
    ],
  }) {
    return {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'assets': assets,
    };
  }

  group('OtaReleasePicker', () {
    test('strips v prefixes and build metadata', () {
      expect(
        OtaReleasePicker.versionOf({'tag_name': 'v1.0.2+3'}),
        '1.0.2',
      );
    });

    test('accepts only SkyTide.apk', () {
      final urls = OtaReleasePicker.apkUrls({
        'assets': [
          {
            'name': 'other.apk',
            'browser_download_url': 'https://example.com/other.apk',
          },
          {
            'name': 'SkyTide.apk',
            'browser_download_url': 'https://example.com/SkyTide.apk',
          },
        ],
      });
      expect(urls, ['https://example.com/SkyTide.apk']);
    });

    test('skips drafts, prereleases and releases without apk', () {
      final picked = OtaReleasePicker.pickLatest([
        release(tag: 'v1.2.0', draft: true),
        release(tag: 'v1.1.0', prerelease: true),
        release(tag: 'v1.0.9', assets: const []),
        release(tag: 'v1.0.3'),
        release(tag: 'v1.0.1'),
      ]);
      expect(picked?['tag_name'], 'v1.0.3');
    });

    test('returns null when no published apk exists', () {
      expect(
        OtaReleasePicker.pickLatest([
          release(tag: 'v2.0.0', draft: true),
          release(tag: 'v2.0.0-beta', prerelease: true),
        ]),
        isNull,
      );
    });
  });
}
