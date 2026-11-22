import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/chat_cache_diagnostics.dart';
import 'package:skytide/chat_message_debounce.dart';
import 'package:skytide/chat_provider_cache.dart';
import 'package:skytide/chat_request_context.dart';

void check(bool condition, String description) {
  if (!condition) throw StateError(description);
}

Future<void> main() async {
  const policy = ChatProviderCache.grok;
  const scope = 'endpoint|new-bot|grok-preset|model|chat';
  final diagnostics = ChatCacheDiagnostics();
  var received = 0;
  final client = MockClient((request) async {
    final turn = ++received;
    check(
      request.headers['x-grok-conv-id'] ==
          policy.requestHeaders(scope)['x-grok-conv-id'],
      'sticky routing within one bot',
    );
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final input = payload['messages'] as List;
    final prefixLength = turn * 2;
    final result = diagnostics.record(
      scope: scope,
      requestId: '$turn',
      payload: payload,
      at: DateTime.utc(2026, 1, 1, 0, 0, turn),
    );
    check(
      result['common_full_messages'] == (turn == 1 ? null : prefixLength - 2),
      'turn $turn: retain the previous user message in the exact prefix',
    );
    check(
      (input[prefixLength - 1] as Map)['role'] == 'user' &&
          (input[prefixLength] as Map)['content'] == 'memory for turn $turn' &&
          (input[prefixLength + 1] as Map)['content'] ==
              'time for turn $turn' &&
          (input[prefixLength] as Map)['role'] == 'system',
      'turn $turn: system context stays authoritative and current',
    );
    return http.Response('{"choices":[{"message":{"content":"reply"}}]}', 200);
  });
  try {
    final rows = <Map<String, dynamic>>[];
    const epoch = 1767225600000;
    const system = {'role': 'system', 'content': 'fixed character prompt'};
    for (var turn = 1; turn <= 4; turn++) {
      final stamp = epoch + turn * 60000;
      final current = {'role': 'user', 'content': 'message $turn'};
      rows.add({...current, 'id': 'u$turn', 'timestamp': stamp});
      final ids = {'u$turn'};
      final history = historyBeforeCurrentBatch(rows, ids);
      final messages = <Map<String, dynamic>>[
        system,
        for (final row in history)
          annotateChatMessage({
            'role': row['role'],
            'content': row['content'],
          }, row['timestamp']),
        {'role': 'system', 'content': 'memory for turn $turn'},
        annotateChatMessage(current, savedUserBatchTimestamp(rows, ids)),
      ];
      moveUserBeforeTurnContext(messages, 1 + history.length);
      messages.add({'role': 'system', 'content': 'time for turn $turn'});
      final response = await client.post(
        Uri.parse('https://grok.example/v1/chat/completions'),
        headers: policy.requestHeaders(scope),
        body: jsonEncode(
          prepareChatCompletionPayload({
            'model': 'grok',
            'messages': prepareOpenAIChatCompletionMessages(messages),
          }),
        ),
      );
      final reply = jsonDecode(response.body)['choices'][0]['message'] as Map;
      rows.add({
        ...reply,
        'role': 'assistant',
        'id': 'a$turn',
        'timestamp': stamp + 1000,
      });
    }
    check(received == 4, 'four requests from a new bot');
    check(
      savedUserBatchTimestamp(rows, {'u2', 'a4', 'u3'}) == epoch + 3 * 60000,
      'choose the last user in a batch without using assistant timestamps',
    );
    check(
      savedUserBatchTimestamp(rows, {'missing'}) == null,
      'missing batch timestamp falls back to the request time',
    );
  } finally {
    client.close();
  }
  print('Grok four-turn cache prefix regression passed.');
}
