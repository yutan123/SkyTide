import 'dart:io';
import 'package:skytide/public_image_http.dart';
import 'package:skytide/model_credential_codec.dart';

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> main() async {
  for (final ip in [
    '0.0.0.0',
    '10.0.0.1',
    '127.0.0.1',
    '169.254.169.254',
    '172.16.0.1',
    '172.31.255.255',
    '192.168.1.1',
    '100.64.0.1',
    '198.18.0.1',
    '192.0.2.1',
    '198.51.100.1',
    '203.0.113.1',
    '224.0.0.1',
    '255.255.255.255',
    '::',
    '::1',
    'fc00::1',
    'fe80::1',
    'ff02::1',
    '::ffff:127.0.0.1',
    '64:ff9b::7f00:1',
    '2002:7f00:1::',
    '2001:db8::1',
    '2001::1',
  ]) {
    check(!isPublicImageAddress(InternetAddress(ip)), 'Must block $ip');
  }
  for (final ip in ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) {
    check(isPublicImageAddress(InternetAddress(ip)), 'Must allow $ip');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var contacted = false;
  server.listen((request) {
    contacted = true;
    request.response.close();
  });
  final client = publicImageHttpClient();
  var blocked = false;
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    await request.close();
  } on SocketException {
    blocked = true;
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
  check(blocked && !contacted, 'Local server must never receive a request');

  final store = <String, String>{};
  Future<void> write(String key, String value) async {
    store[key] = value;
  }

  Future<String?> read(String key) async => store[key];
  const key = 'web_search_api_key';
  final protected = await ModelCredentialCodec.protectKey(
    key,
    'search-secret',
    write,
  );
  check(protected != 'search-secret', 'Search key must be protected');
  check(
    await ModelCredentialCodec.resolveKey(key, protected, read) ==
        'search-secret',
    'Search key must resolve unchanged',
  );
  check(
    await ModelCredentialCodec.protectKey(key, protected, write) == protected,
    'Migration must preserve existing search references',
  );
  final refs = ModelCredentialCodec.references(key, protected);
  final restored = {for (final id in refs) id: store[id]!};
  check(
    await ModelCredentialCodec.resolveKey(
          key,
          protected,
          (id) async => restored[id],
        ) ==
        'search-secret',
    'Search key must restore on another device',
  );
  check(
    !ModelCredentialCodec.handles('external_api_key'),
    'External key is excluded',
  );
  check(
    await ModelCredentialCodec.protectKey(key, '', write) == '',
    'Empty keys stay empty',
  );
  print(
    'Security address policy, local connection blocking and search credential checks passed.',
  );
}
