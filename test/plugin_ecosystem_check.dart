import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/plugin_ai.dart';
import 'package:skytide/plugin_worker_policy.dart';
import 'package:skytide/plugin_data_policy.dart';
import 'package:skytide/plugin_event_policy.dart';

int checks = 0;
void expect(bool value, String label) {
  if (!value) throw StateError(label);
  checks++;
}

Future<void> rejects(FutureOr<dynamic> Function() work, String label) async {
  try {
    await work();
  } catch (_) {
    checks++;
    return;
  }
  throw StateError('Expected rejection: $label');
}

Future<void> main() async {
  Future<void> current() async {}
  expect(PluginWorkerPolicy.validate(null).isEmpty, 'legacy manifest');
  expect(
    PluginWorkerPolicy.validate([
          {'name': 'sync'},
        ]).single['intervalMs'] ==
        5000,
    'default interval',
  );
  for (final value in [
    false,
    [
      {'name': 'loop', 'intervalMs': 0},
    ],
    [
      {'name': 'loop'},
      {'name': 'loop'},
    ],
    List.generate(9, (i) => {'name': 'w$i'}),
  ]) {
    await rejects(() => PluginWorkerPolicy.validate(value), 'invalid workers');
  }
  expect(PluginWorkerPolicy.backoff(1000, 1) == 2000, 'failure backoff');
  expect(PluginWorkerPolicy.backoff(1000, 99) == 64000, 'bounded exponent');
  expect(
    PluginWorkerPolicy.backoff(86400000, 2) == 86400000,
    'never shorten slow interval',
  );
  final waits = PluginWaits();
  await waits.sleep(1, current);
  checks++;
  await rejects(() => waits.sleep(0, current), 'zero delay');
  final pending = waits.sleep(60000, current);
  final cancelled = rejects(() => pending, 'stop cancels waits');
  await Future<void>.delayed(Duration.zero);
  waits.close();
  await cancelled;
  await rejects(() => waits.sleep(1, current), 'closed waits');
  final bounded = PluginWaits();
  final waiting = List.generate(32, (_) => bounded.sleep(60000, current));
  final observed = waiting
      .map((p) => rejects(() => p, 'pending wait cancelled'))
      .toList();
  await Future<void>.delayed(Duration.zero);
  await rejects(() => bounded.sleep(1, current), 'wait concurrency');
  bounded.close();
  await Future.wait(observed);
  expect(
    PluginDataPolicy.similarity(
          PluginDataPolicy.vector([3, 4]),
          PluginDataPolicy.vector([6, 8]),
        ) >
        .999,
    'cosine normalization',
  );
  expect(PluginDataPolicy.similarity([1, 0], [-1, 0]) == -1, 'opposite vector');
  for (final vector in [
    [],
    [0, 0],
    [double.nan],
    [double.infinity],
    [1e308, 1e308],
  ]) {
    await rejects(() => PluginDataPolicy.vector(vector), 'invalid vector');
  }
  await rejects(
    () => PluginDataPolicy.similarity([1], [1, 0]),
    'dimension mismatch',
  );
  await rejects(() => PluginDataPolicy.key('a\u0000b'), 'NUL key');
  await rejects(() => PluginDataPolicy.name('../host'), 'collection isolation');
  await rejects(
    () => PluginDataPolicy.encode('字' * 50000),
    'UTF8 record limit',
  );
  expect(
    PluginEventPolicy.match('/echo hello\nworld', ['echo'])?['text'] ==
        'hello\nworld',
    'multiline command',
  );
  expect(
    PluginEventPolicy.match('/echoes', ['echo']) == null,
    'whole command matching',
  );
  expect(
    PluginEventPolicy.match('text /echo', ['echo']) == null,
    'command at start',
  );
  await rejects(
    () => PluginEventPolicy.commands(['echo', 'echo']),
    'duplicate commands',
  );
  await rejects(() => PluginEventPolicy.priority(101), 'priority range');

  final provider = {
    'id': 'legacy_with_private_url',
    'name': 'Test',
    'model': 'one,two',
    'base_url': 'https://example.test/gateway/v1',
    'api_key': 'private-secret',
  };
  final captured = <http.Request>[];
  var active = true;
  final ai = PluginAI(
    check: () async {
      if (!active) throw StateError('stopped');
    },
    providers: () async => [provider],
    clientFactory: () => MockClient((request) async {
      captured.add(request);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'answer'},
            },
          ],
        }),
        200,
      );
    }),
  );
  final models = await ai.call('ai.listModels', {}) as List;
  expect(
    !jsonEncode(models).contains('private') &&
        !jsonEncode(models).contains('https:'),
    'model list hides keys endpoints and legacy IDs',
  );
  final options = <String, dynamic>{
    'requestId': 'r1',
    'providerId': models.single['id'],
    'messages': [
      {'role': 'user', 'content': 'hello', 'injected': 'ignored'},
    ],
  };
  final result = await ai.call('ai.generate', options);
  expect(result['text'] == 'answer', 'text generation');
  expect(
    captured.single.url.toString() ==
        'https://example.test/gateway/v1/chat/completions',
    'provider gateway endpoint',
  );
  expect(
    captured.single.headers['Authorization'] == 'Bearer private-secret',
    'host credential attached',
  );
  expect(
    !captured.single.followRedirects,
    'credentials cannot follow redirects',
  );
  final body = jsonDecode(captured.single.body) as Map;
  expect(
    body['stream'] == false &&
        body['messages'][0]['injected'] == null &&
        !body.containsKey('tools'),
    'stateless bounded text request',
  );
  await rejects(
    () => ai.call('ai.generate', {...options, 'model': 'unknown'}),
    'model allowlist',
  );
  await rejects(
    () => ai.call('ai.generate', {...options, 'maxTokens': 9000}),
    'token bound',
  );
  await rejects(
    () => ai.call('ai.generate', {
      ...options,
      'messages': [
        {'role': 'tool', 'content': 'x'},
      ],
    }),
    'role bound',
  );
  active = false;
  await rejects(
    () => ai.call('ai.generate', options),
    'lifecycle invalidation',
  );
  ai.close();

  final response = Completer<http.Response>();
  final blocking = PluginAI(
    check: current,
    providers: () async => [provider],
    clientFactory: () => MockClient((_) => response.future),
  );
  final inflight = blocking.call('ai.generate', options);
  final stopped = rejects(
    () => inflight,
    'cancelled request cannot resolve success',
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
  await rejects(() => blocking.call('ai.generate', options), 'ID reserved');
  expect(
    await blocking.call('ai.cancel', {'requestId': 'r1'}) == true,
    'cancel receipt',
  );
  response.complete(
    http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': 'late'},
          },
        ],
      }),
      200,
    ),
  );
  await stopped;
  blocking.close();
  final malformed = PluginAI(
    check: current,
    providers: () async => [provider],
    clientFactory: () =>
        MockClient((_) async => http.Response('private-secret', 200)),
  );
  try {
    await malformed.call('ai.generate', options);
    throw StateError('expected failure');
  } catch (error) {
    expect(
      !error.toString().contains('private-secret'),
      'parse error redaction',
    );
  }
  malformed.close();
  print('Plugin ecosystem checks passed: $checks');
}
