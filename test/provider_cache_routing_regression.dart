import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/chat_api_endpoint.dart';
import 'package:skytide/chat_provider_cache.dart';
import 'package:skytide/native_chat_api.dart';

void check(bool condition, String description) {
  if (!condition) throw StateError(description);
}

Future<void> main() async {
  final presets = {
    'ChatGPT': ChatProviderCache.gpt,
    'Grok': ChatProviderCache.grok,
    'Claude': ChatProviderCache.claude,
    'Gemini': ChatProviderCache.gemini,
    'DeepSeek': ChatProviderCache.deepSeek,
    'Mimo': ChatProviderCache.mimo,
    'MiniMax': ChatProviderCache.miniMax,
    'SiliconFlow': ChatProviderCache.siliconFlow,
    '阿里云百炼': ChatProviderCache.dashScope,
    'Kimi': ChatProviderCache.kimi,
    'Gitee AI': ChatProviderCache.gitee,
  };
  const gateway = 'https://gateway.example:8443/proxy/v1?tenant=a';
  for (final entry in presets.entries) {
    final provider = {
      'preset_name': entry.key,
      'name': 'Renamed',
      'base_url': gateway,
    };
    check(ChatProviderCache.resolve(provider) == entry.value, entry.key);
    check(
      ChatProviderCache.resolve({...provider, 'is_custom': true}) ==
          ChatProviderCache.compatible,
      'custom ${entry.key}',
    );
  }
  const grok = ChatProviderCache.grok;
  final conv = grok.requestHeaders('conversation')['x-grok-conv-id'];
  check(
    conv != null &&
        grok.requestHeaders('conversation')['x-grok-conv-id'] == conv &&
        grok.requestHeaders('other')['x-grok-conv-id'] != conv,
    'Grok routing key',
  );
  final options = grok.requestOptions('conversation', stream: true);
  check(
    options.length == 1 && options['stream_options']['include_usage'] == true,
    'Grok streaming options',
  );
  check(
    grok.usage({
          'prompt_tokens': 125,
          'prompt_tokens_details': {'cached_tokens': 98},
        }) ==
        (hit: 98, miss: 27, written: null),
    'Grok usage',
  );

  const compatible =
      'https://gateway.example/proxy/v1/chat/completions?tenant=a';
  for (final api in NativeChatApi.values) {
    final provider = {'preset_name': api.preset};
    check(
      NativeChatApi.resolve(provider, gateway) == api,
      'native gateway ${api.preset}',
    );
    check(
      NativeChatApi.resolve(provider, compatible) == null &&
          chatApiEndpoint(compatible) == compatible,
      'explicit compatibility ${api.preset}',
    );
    check(
      NativeChatApi.resolve({...provider, 'is_custom': true}, gateway) == null,
      'custom protocol',
    );
  }

  var pages = 0;
  final models = await http.runWithClient(
    () => NativeChatApi.claude.listModels('test-key', baseUrl: gateway),
    () => MockClient((request) async {
      check(
        request.url.host == 'gateway.example' &&
            request.url.port == 8443 &&
            request.url.path == '/proxy/v1/models',
        'model list URL',
      );
      check(
        request.url.queryParameters['tenant'] == 'a' &&
            request.headers['x-api-key'] == 'test-key',
        'model list query and auth',
      );
      pages++;
      check(
        request.url.queryParameters['after_id'] ==
            (pages == 1 ? null : 'first'),
        'pagination cursor',
      );
      return http.Response(
        jsonEncode({
          'data': [
            {'id': pages == 1 ? 'first' : 'second'},
          ],
          'has_more': pages == 1,
          'last_id': 'first',
        }),
        200,
      );
    }),
  );
  check(pages == 2 && models.join(',') == 'first,second', 'pagination');

  final tested = await http.runWithClient(
    () => NativeChatApi.claude.testConnection(
      'test-key',
      'first, second',
      baseUrl: gateway,
    ),
    () => MockClient((request) async {
      check(
        request.url.toString() ==
            'https://gateway.example:8443/proxy/v1/messages?tenant=a',
        'Claude chat URL',
      );
      check(
        request.headers['x-api-key'] == 'test-key' &&
            jsonDecode(request.body)['model'] == 'first',
        'Claude native auth and model',
      );
      return http.Response('{"content":[{"type":"text","text":"OK"}]}', 200);
    }),
  );
  check(tested['passed'] == true, 'native connection test');

  final client = MockClient((request) async {
    check(
      request.url.path ==
          '/proxy/v1beta/models/gemini-test:streamGenerateContent',
      'Gemini chat URL',
    );
    check(
      request.url.queryParameters['tenant'] == 'a' &&
          request.url.queryParameters['alt'] == 'sse',
      'Gemini SSE query',
    );
    check(
      request.headers['x-goog-api-key'] == 'test-key',
      'Gemini native auth',
    );
    return http.Response(
      'data: {"candidates":[{"finishReason":"STOP"}],'
      '"usageMetadata":{"promptTokenCount":125,"cachedContentTokenCount":98}}\n\n',
      200,
    );
  });
  try {
    final request = http.Request('POST', Uri.parse(compatible))
      ..headers['Authorization'] = 'Bearer test-key'
      ..body = jsonEncode({
        'model': 'gemini-test',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      });
    final response = await NativeChatApi.gemini.send(
      client,
      request,
      baseUrl: 'https://gateway.example/proxy?tenant=a',
    );
    await response.stream.drain<void>();
    check(response.statusCode == 200, 'Gemini stream response');
  } finally {
    client.close();
  }
  print('Provider cache and native routing regressions passed.');
}
