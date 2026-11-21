import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:skytide/chat_provider_cache.dart';
import 'package:skytide/native_chat_api.dart';
import 'package:skytide/tool_completion.dart';

void check(bool result, String label) {
  if (!result) throw StateError(label);
}

Future<void> main() async {
  const url = 'https://api.openai.com/v1';
  final official = ChatProviderCache.resolve({
    'preset_name': 'ChatGPT',
    'base_url': url,
  });
  final custom = ChatProviderCache.resolve({
    'preset_name': 'ChatGPT',
    'base_url': url,
    'is_custom': true,
  });
  check(
    official
        .requestOptions('scope', stream: true)
        .containsKey('prompt_cache_key'),
    'official cache key',
  );
  check(
    !custom
        .requestOptions('scope', stream: true)
        .containsKey('prompt_cache_key'),
    'custom cache isolation',
  );
  const geminiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta';
  const gemini = NativeChatApi.gemini;
  const claude = NativeChatApi.claude;
  check(
    NativeChatApi.resolve({
          'preset_name': 'Gemini',
          'is_custom': true,
        }, geminiBaseUrl) ==
        null,
    'custom Gemini isolation',
  );
  final messages = <Map<String, dynamic>>[
    {'role': 'system', 'content': 'Stable'},
    {'role': 'user', 'content': 'Question'},
    {'role': 'system', 'content': 'Dynamic'},
  ];
  final payload = {
    'model': 'future-model',
    'messages': messages,
    'stream': true,
  };
  final anthropic = claude.encode(payload);
  check(
    anthropic['system'].first['cache_control']['type'] == 'ephemeral',
    'Claude cache marker',
  );
  check(
    anthropic['messages'].last['content'].last['text'].contains('Dynamic'),
    'dynamic context not cached as system prefix',
  );
  final stats = ChatProviderCache.claude.usage(
    claude.usage({
      'input_tokens': 10,
      'cache_read_input_tokens': 100,
      'cache_creation_input_tokens': 20,
    }),
  );
  check(
    stats.hit == 100 && stats.miss == 30 && stats.written == 20,
    'Claude accounting',
  );
  final client = MockClient((request) async {
    check(
      request.url.path == '/v1beta/models/future-model:streamGenerateContent',
      'future model route',
    );
    check(
      request.headers['x-goog-api-key'] == 'test' &&
          !request.headers.containsKey('authorization'),
      'Gemini authentication',
    );
    final chunk = {
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {'name': 'lookup', 'args': {}, 'id': 'wire-1'},
                'thoughtSignature': 'opaque',
              },
              {
                'functionCall': {
                  'name': 'lookup',
                  'args': {'q': 'two'},
                },
              },
            ],
          },
          'finishReason': 'STOP',
        },
      ],
      'usageMetadata': {
        'promptTokenCount': 200,
        'cachedContentTokenCount': 128,
      },
    };
    return http.Response(
      'data: ${jsonEncode(chunk)}\n\n',
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  try {
    final response = await gemini.send(
      client,
      http.Request('POST', Uri.parse(geminiBaseUrl))
        ..headers['Authorization'] = 'Bearer test'
        ..body = jsonEncode(payload),
      baseUrl: geminiBaseUrl,
    );
    final (decoded, streamed) = await readToolCompletion(response.stream);
    final assistant = toolAssistantMessage(decoded['choices'].first['message']);
    final calls = assistant['tool_calls'] as List;
    check(streamed && calls.length == 2, 'parallel tools');
    check(
      calls.first['native_thought_signature'] == 'opaque',
      'signature survives SSE',
    );
    check(
      ChatProviderCache.gemini.usage(decoded['usage']).hit == 128,
      'Gemini cached usage',
    );
    final next = gemini.encode({
      ...payload,
      'messages': [
        ...messages,
        assistant,
        for (final call in calls)
          {'role': 'tool', 'tool_call_id': call['id'], 'content': 'ok'},
      ],
    });
    final turns = next['contents'] as List;
    check(
      turns[turns.length - 2]['parts'].first['thoughtSignature'] == 'opaque',
      'signature replay',
    );
    check(
      turns.last['parts'].first['functionResponse']['id'] == 'wire-1',
      'Gemini function response ID',
    );
    check(turns.last['parts'].length == 2, 'parallel tool results');
  } finally {
    client.close();
  }
  print('Provider protocol checks passed');
}
