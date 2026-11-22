import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:skytide/chat_provider_cache.dart';
import 'package:skytide/chat_gpt_responses.dart';
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
  check(official == ChatProviderCache.gpt, 'ChatGPT preset routing');
  check(custom == ChatProviderCache.compatible, 'custom cache isolation');
  await checkResponses();
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

Future<void> checkResponses() async {
  const root = 'https://gateway.example/proxy/v1';
  final endpoint = ChatGptResponses.endpoint('$root/chat/completions');
  check(endpoint.toString() == '$root/responses', 'Responses endpoint');
  check(
    ChatGptResponses.endpoint('$root/responses/') == endpoint,
    'full Responses endpoint',
  );
  final adapter = ChatGptResponses('bot/provider/model');
  final chat = <String, dynamic>{
    'model': 'gpt-test',
    'messages': [
      {'role': 'system', 'content': 'fixed instructions'},
      {'role': 'user', 'content': 'history'},
      {'role': 'system', 'content': 'dynamic clock'},
      {'role': 'user', 'content': 'question'},
    ],
    'tools': [
      {
        'type': 'function',
        'function': {
          'name': 'lookup',
          'parameters': {'type': 'object'},
        },
      },
    ],
    'tool_choice': 'auto',
    'reasoning_effort': 'high',
    'max_completion_tokens': 512,
    'stream': true,
    'stream_options': {'include_usage': true},
    'prompt_cache_options': {'mode': 'explicit'},
  };
  final initial = adapter.payload(chat);
  final next = ChatGptResponses('bot/provider/model').payload({
    ...chat,
    'messages': [
      ...chat['messages'].take(2),
      {'role': 'user', 'content': 'question'},
      {'role': 'assistant', 'content': 'answer'},
      {'role': 'system', 'content': 'new clock'},
      {'role': 'user', 'content': 'next question'},
    ],
  });
  check(
    initial['prompt_cache_key'] == next['prompt_cache_key'],
    'stable cross-turn routing key',
  );
  for (var i = 0; i < 2; i++) {
    check(
      jsonEncode(initial['input'][i]) == jsonEncode(next['input'][i]),
      'stable wire prefix $i',
    );
  }
  const metering = {
    'input_tokens': 1200,
    'input_tokens_details': {'cached_tokens': 1024},
    'output_tokens': 12,
  };
  final client = MockClient((request) async {
    check(request.url == endpoint, 'Responses HTTP URL');
    final body = jsonDecode(request.body) as Map;
    check(
      !body.containsKey('messages') &&
          !body.containsKey('stream_options') &&
          !jsonEncode(body).contains('prompt_cache_options') &&
          !jsonEncode(body).contains('prompt_cache_breakpoint'),
      'no unsupported cache parameters',
    );
    check(
      body['input'][0]['role'] == 'developer' &&
          body['input'][0]['content'][0]['type'] == 'input_text',
      'developer input',
    );
    check(
      body['tools'][0]['name'] == 'lookup' &&
          body['reasoning']['effort'] == 'high' &&
          body['max_output_tokens'] == 512,
      'tool and reasoning schema',
    );
    final continuation = body['stream'] != true;
    if (continuation) {
      final input = body['input'] as List;
      check(
        input.any((item) => item['encrypted_content'] == 'encrypted'),
        'stateless reasoning replay',
      );
      check(
        input[input.length - 2]['call_id'] == 'call_1' &&
            input.last['type'] == 'function_call_output' &&
            input.last['call_id'] == 'call_1',
        'paired tool callback',
      );
      check(
        body['prompt_cache_key'] == initial['prompt_cache_key'],
        'same tool continuation cache key',
      );
    }
    final result = {
      'status': 'completed',
      'usage': metering,
      'output': continuation
          ? [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '完成'},
                ],
              },
            ]
          : [
              {
                'type': 'reasoning',
                'id': 'rs_1',
                'encrypted_content': 'encrypted',
                'summary': [],
              },
              {
                'type': 'function_call',
                'id': 'fc_1',
                'call_id': 'call_1',
                'name': 'lookup',
                'arguments': '{}',
              },
            ],
    };
    return continuation
        ? http.Response(
            jsonEncode(result),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )
        : http.Response(
            'data: ${jsonEncode({'type': 'response.completed', 'response': result})}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
  });
  Future<(Map<String, dynamic>, bool)> send(
    Map<String, dynamic> payload,
  ) async {
    final request = http.Request('POST', endpoint)..body = jsonEncode(payload);
    final result = await adapter.send(client, request);
    return readToolCompletion(result.stream);
  }

  try {
    final (first, streamed) = await send(initial);
    final message = first['choices'][0]['message'] as Map;
    check(
      streamed && message['tool_calls'][0]['id'] == 'call_1',
      'SSE tool event',
    );
    const cache = ChatProviderCache.gpt;
    check(
      cache.usage(first['usage']).hit == 1024 &&
          cache.usage(first['usage']).miss == 176,
      'Responses cache metering',
    );
    check(
      cache.usage({
                'input_tokens_details': {'cached_tokens': 0},
              }).hit ==
              0 &&
          cache.usage({}).hit == null,
      'explicit zero differs from missing usage',
    );
    final (last, finalStream) = await send(
      adapter.payload({
        ...chat,
        'stream': false,
        'messages': [
          ...chat['messages'],
          toolAssistantMessage(message),
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'tool result'},
        ],
      }),
    );
    check(
      !finalStream && last['choices'][0]['message']['content'] == '完成',
      'JSON response',
    );
  } finally {
    client.close();
  }
}
