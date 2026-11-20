import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:skytide/plugin_oauth.dart';
import 'package:skytide/plugin_crypto.dart';

Future<void> main() async {
  var checks = 0;
  void expect(bool result, String label) {
    if (!result) throw StateError(label);
    checks++;
  }

  final oauth = PluginOAuth();
  final client = HttpClient();
  const origin = 'https://accounts.example.com';
  final args = {
    'url': '$origin/authorize',
    'parameters': {
      'client_id': 'test',
      'scope': 'mail',
      'state': 'must-be-overwritten',
    },
  };
  try {
    final value = await oauth.authorize(args, [origin], () async {}, (
      target,
    ) async {
      final query = target.queryParameters;
      expect(query['state'] != 'must-be-overwritten', 'host controls state');
      expect(
        query['response_type'] == 'code' &&
            query['code_challenge_method'] == 'S256',
        'PKCE authorization URL',
      );
      final callback = Uri.parse(query['redirect_uri']!);
      expect(callback.host == '127.0.0.1', 'callback loopback only');
      final bad = await client.getUrl(
        callback.replace(queryParameters: {'code': 'bad', 'state': 'wrong'}),
      );
      final badResponse = await bad.close();
      expect(badResponse.statusCode == 400, 'CSRF callback rejected');
      await badResponse.drain<void>();
      final request = await client.getUrl(
        callback.replace(
          queryParameters: {'code': 'verified', 'state': query['state']!},
        ),
      );
      final response = await request.close();
      expect(response.statusCode == 200, 'valid callback accepted');
      await response.drain<void>();
      return true;
    });
    expect(value['code'] == 'verified', 'code returned');
    final challenge = await PluginCrypto.call('crypto.digest', {
      'base64': base64Encode(ascii.encode(value['verifier'] as String)),
    });
    expect((challenge['base64'] as String).isNotEmpty, 'verifier usable');
    var launchRejected = false;
    try {
      await oauth.authorize(args, [], () async {}, (_) async => true);
    } catch (_) {
      launchRejected = true;
    }
    expect(launchRejected, 'authorization origin checked');
    final launched = Completer<void>();
    final pending = oauth.authorize(args, [origin], () async {}, (_) async {
      launched.complete();
      return true;
    });
    final rejection = pending.then((_) => false, onError: (Object _) => true);
    await launched.future;
    oauth.close();
    expect(await rejection, 'disable cancels browser authorization');
    print('Plugin OAuth checks passed: $checks');
  } finally {
    oauth.close();
    client.close(force: true);
  }
}
