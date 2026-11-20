import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/plugin_network.dart';
import 'package:skytide/plugin_error.dart';
import 'package:skytide/plugin_operation.dart';

Future<void> main() async {
  var checks = 0;
  void expect(bool value) {
    if (!value) throw StateError('check $checks');
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

  final network = PluginNetwork(
    createClient: () => MockClient((request) async {
      expect(!request.followRedirects);
      if (request.url.path == '/upload') {
        expect(
          request.headers['content-type']!.startsWith('multipart/form-data;'),
        );
        expect(
          request.body.contains('hello.txt') && request.body.contains('hello'),
        );
      }
      return http.Response('ok', 200);
    }),
  );
  const origins = ['https://example.com'];
  final reply = await network.request(
    {
      'requestId': 'one',
      'url': 'https://example.com/upload',
      'method': 'POST',
      'multipart': [
        {
          'name': 'file',
          'filename': 'hello.txt',
          'base64': base64Encode(utf8.encode('hello')),
        },
      ],
    },
    origins,
    () async {},
  );
  expect(reply['body'] == 'ok');
  final progress =
      network.control('http.progress', {'requestId': 'one'}) as Map;
  expect(
    progress['state'] == 'finished' &&
        progress['received'] == 2 &&
        progress['sent'] > 0,
  );
  expect(network.control('http.cancel', {'requestId': 'one'}) == false);
  await rejects(
    () => network.request(
      {'requestId': 'one', 'url': 'https://example.com'},
      origins,
      () async {},
    ),
  );
  await rejects(
    () => network.request(
      {'requestId': 'bad', 'url': 'https://evil.test'},
      origins,
      () async {},
    ),
  );
  await rejects(
    () => network.request(
      {'requestId': 'bad', 'url': 'https://example.com', 'timeoutMs': 0},
      origins,
      () async {},
    ),
  );
  final gate = Completer<void>();
  final first = network.request(
    {'requestId': 'race', 'url': 'https://example.com'},
    origins,
    () => gate.future,
  );
  final second = network.request(
    {'requestId': 'race', 'url': 'https://example.com'},
    origins,
    () => gate.future,
  );
  final rejected = rejects(() => second);
  gate.complete();
  await first;
  await rejected;
  network.close();
  await rejects(
    () => network.request(
      {'requestId': 'closed', 'url': 'https://example.com'},
      origins,
      () async {},
    ),
  );
  for (final entry in [
    [const PluginOperationCancelled(), 'CANCELLED'],
    [TimeoutException('late'), 'TIMEOUT'],
    [const FormatException('bad'), 'INVALID_ARGUMENT'],
    [StateError('stopped'), 'INVALID_STATE'],
  ]) {
    expect(jsonDecode(pluginHostError(entry[0]))['code'] == entry[1]);
  }
  final responseGate = Completer<http.Response>();
  final started = Completer<void>();
  final cancellable = PluginNetwork(
    createClient: () => MockClient((_) {
      started.complete();
      return responseGate.future;
    }),
  );
  final pending = cancellable.request(
    {'requestId': 'cancel', 'url': 'https://example.com'},
    origins,
    () async {},
  );
  final cancellation = rejects(() => pending);
  await started.future;
  expect(cancellable.control('http.cancel', {'requestId': 'cancel'}) == true);
  responseGate.complete(http.Response('ignored', 200));
  await cancellation;
  expect(
    cancellable.control('http.progress', {'requestId': 'cancel'})['state'] ==
        'cancelled',
  );
  cancellable.close();
  print('Plugin network/error: $checks checks passed');
}
