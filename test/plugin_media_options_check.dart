import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:skytide/plugin_chat_session.dart';
import 'package:skytide/plugin_media_contract.dart';
import 'package:skytide/plugin_network.dart';
import 'package:http/testing.dart';
import 'plugin_chat_session_check.dart' show Host;

Future<void> main() async {
  var checks = 0;
  void expect(bool value, String label) {
    if (!value) throw StateError(label);
    checks++;
  }

  Future<void> rejects(Future<dynamic> Function() work) async {
    try {
      await work();
    } catch (_) {
      checks++;
      return;
    }
    throw StateError('expected rejection');
  }

  for (final origin in [
    '*',
    'https://*.bilivideo.com',
    'https://cdn.example.com:8443',
  ]) {
    expect(PluginMediaContract.validOrigin(origin), 'valid origin $origin');
  }
  for (final origin in [
    'https://foo.*.com',
    'https://*.example.com/path',
    'http://*.example.com',
    'https://user@example.com',
  ]) {
    expect(!PluginMediaContract.validOrigin(origin), 'invalid origin $origin');
  }
  bool allowed(String url, List<String> origins) =>
      PluginMediaContract.allows(Uri.parse(url), origins);
  expect(
    allowed('https://a.b.bilivideo.com/v', ['https://*.bilivideo.com']),
    'nested CDN',
  );
  expect(
    !allowed('https://bilivideo.com/v', ['https://*.bilivideo.com']),
    'apex needs its own declaration',
  );
  expect(
    !allowed('https://evilbilivideo.com/v', ['https://*.bilivideo.com']),
    'suffix boundary',
  );
  expect(
    !allowed('https://a.bilivideo.com:8443/v', ['https://*.bilivideo.com']),
    'port boundary',
  );
  expect(allowed('https://any.example:8443/v', ['*']), 'explicit all HTTPS');
  expect(!allowed('http://any.example/v', ['*']), 'HTTPS only');
  final root = await Directory.systemTemp.createTemp('plugin-media-options-');
  final host = Host(root);
  final session = PluginChatSession(
    pluginId: 'tidebot.test',
    botId: 'a',
    host: host,
    assertCurrent: () async {},
  );
  const permissions = ['network', 'media.download', 'chat.send'];
  final requests = <http.Request>[];
  host.respond = (request) async {
    requests.add(request);
    if (request.url.host == 'api.example.com') {
      return http.Response(
        '',
        302,
        headers: {'location': 'https://edge.cdn.example.com/video'},
      );
    }
    expect(
      request.headers['referer'] == 'https://www.bilibili.com/',
      'referer survives redirect',
    );
    expect(
      request.headers['user-agent'] == 'PluginTest',
      'user agent survives redirect',
    );
    expect(
      !request.headers.containsKey('cookie') &&
          !request.headers.containsKey('authorization'),
      'cross-origin credentials removed',
    );
    return http.Response.bytes([
      0,
      0,
      0,
      24,
      102,
      116,
      121,
      112,
      105,
      115,
      111,
      109,
    ], 200);
  };
  try {
    final receipt = await session.call(
      'chat.sendVideo',
      {
        'url': 'https://api.example.com/start',
        'requestId': 'video',
        'headers': {
          'Referer': 'https://www.bilibili.com/',
          'User-Agent': 'PluginTest',
          'Cookie': 'session=secret',
          'Authorization': 'Bearer secret',
        },
        'timeoutMs': 10000,
      },
      permissions,
      ['https://api.example.com', 'https://*.cdn.example.com'],
    );
    expect(
      receipt['status'] == 'sent' && requests.length == 2,
      'download and send',
    );
    expect(
      requests.first.headers['cookie'] == 'session=secret',
      'initial request credentials',
    );
    await rejects(
      () => session.call(
        'media.download',
        {'url': 'https://api.example.com', 'kind': 'video', 'timeoutMs': 0},
        permissions,
        ['*'],
      ),
    );
    await rejects(
      () => session.call(
        'media.download',
        {
          'url': 'https://api.example.com',
          'kind': 'video',
          'headers': {'Referer': 'bad\r\nInjected: yes'},
        },
        permissions,
        ['*'],
      ),
    );
    host.respond = (_) async => http.Response(
      '',
      302,
      headers: {'location': 'https://unapproved.example/v'},
    );
    await rejects(
      () => session.call(
        'media.download',
        {'url': 'https://api.example.com', 'kind': 'video'},
        permissions,
        ['https://api.example.com'],
      ),
    );
    var hops = 0;
    host.respond = (request) async {
      expect(
        request.headers['cookie'] == 'same-origin',
        'same-origin credential retained',
      );
      if (hops++ == 0)
        return http.Response('', 302, headers: {'location': '/final'});
      return http.Response.bytes([137, 80, 78, 71, 13, 10, 26, 10], 200);
    };
    await session.call(
      'media.download',
      {
        'url': 'https://api.example.com/start',
        'kind': 'image',
        'headers': {'Cookie': 'same-origin'},
      },
      permissions,
      ['*'],
    );
  } finally {
    await session.close();
    await root.delete(recursive: true);
  }
  final network = PluginNetwork(
    createClient: () => MockClient((r) async {
      expect(r.method == 'HEAD' || r.method == 'OPTIONS', 'new HTTP methods');
      return http.Response('', 200);
    }),
  );
  try {
    for (final method in ['HEAD', 'OPTIONS']) {
      await network.request(
        {
          'requestId': method,
          'url': 'https://edge.cdn.example.com/v',
          'method': method,
        },
        ['https://*.cdn.example.com'],
        () async {},
      );
    }
  } finally {
    network.close();
  }
  print('Plugin media/network extensions: $checks checks passed');
}
