import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'chat_api_endpoint.dart';

/// Adapts Chat Completions transcripts to the Responses protocol.
/// A single instance lives for the initial request and its tool continuations.
class ChatGptResponses {
  ChatGptResponses(this.scope, {this.grok = false});

  final bool grok;

  final String scope;
  final _toolOutputByCallId = <String, List<Map>>{};

  static Uri endpoint(String configured) {
    final original = Uri.parse(configured.trim());
    final path = original.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/responses')) {
      return original.replace(path: path).removeFragment();
    }
    final uri = Uri.parse(chatApiBase(configured));
    return uri.replace(path: '${uri.path}/responses').removeFragment();
  }

  Map<String, dynamic> payload(Map<String, dynamic> chat) {
    final messages = (chat['messages'] as List).whereType<Map>().toList();
    final tools = [
      for (final tool in (chat['tools'] as List? ?? const []).whereType<Map>())
        if (tool['function'] case final Map function)
          <String, dynamic>{'type': 'function', 'strict': false, ...function},
    ];
    // Use the fixed leading instruction as the anchor. A first user message
    // may only become part of history on the next turn; it must not re-key it.
    final anchor = messages.isNotEmpty && messages.first['role'] == 'system'
        ? messages.first['content']
        : null;
    final digest = sha256.convert(
      utf8.encode(jsonEncode([scope, chat['model'], anchor, tools])),
    );
    final choice = chat['tool_choice'];
    return {
      'model': chat['model'],
      'input': [for (final message in messages) ..._input(message)],
      if (!grok)
        'prompt_cache_key':
            'skytide_resp_${digest.toString().substring(0, 48)}',
      'store': false,
      if ((chat['max_completion_tokens'] ?? chat['max_tokens'])
          case final int limit)
        'max_output_tokens': limit,
      if (!grok && chat['reasoning_effort'] is String)
        'reasoning': {'effort': chat['reasoning_effort']},
      if (tools.isNotEmpty) ...{
        'tools': tools,
        'include': ['reasoning.encrypted_content'],
        if (choice != null)
          'tool_choice': choice is Map
              ? {
                  'type': 'function',
                  'name': (choice['function'] as Map)['name'],
                }
              : choice,
      },
      if (chat['stream'] == true) 'stream': true,
    };
  }

  Iterable<Map> _input(Map message) sync* {
    final role = message['role'];
    final content = message['content'];
    if (role == 'tool') {
      yield {
        'type': 'function_call_output',
        'call_id': message['tool_call_id'],
        'output': content,
      };
      return;
    }
    final calls = (message['tool_calls'] as List? ?? const []).whereType<Map>();
    if (calls.isNotEmpty) {
      final output = _toolOutputByCallId[calls.first['id']];
      if (output != null) {
        yield* output;
        return;
      }
    }
    final parts = content is String
        ? <Map>[
            if (content.isNotEmpty)
              {
                'type': role == 'assistant' ? 'output_text' : 'input_text',
                'text': content,
              },
          ]
        : [
            for (final part in (content as List? ?? const []).whereType<Map>())
              if (part['type'] == 'text')
                {
                  'type': role == 'assistant' ? 'output_text' : 'input_text',
                  'text': part['text'],
                }
              else if (part['type'] == 'image_url' && part['image_url'] is Map)
                {
                  'type': 'input_image',
                  'image_url': (part['image_url'] as Map)['url'],
                  'detail': (part['image_url'] as Map)['detail'] ?? 'auto',
                }
              else
                Map.of(part)..remove('cache_control'),
          ];
    if (parts.isNotEmpty) {
      yield {
        'type': 'message',
        'role': role == 'system' ? 'developer' : role,
        'content': parts,
      };
    }
    for (final call in calls) {
      final function = call['function'] as Map;
      yield {
        'type': 'function_call',
        'call_id': call['id'],
        'name': function['name'],
        'arguments': function['arguments'] ?? '{}',
      };
    }
  }

  Map<String, dynamic> _completion(Map response) {
    final text = StringBuffer();
    final calls = <Map>[];
    final replay = <Map>[];
    for (final item
        in (response['output'] as List? ?? const []).whereType<Map>()) {
      switch (item['type']) {
        case 'message':
          for (final part
              in (item['content'] as List? ?? const []).whereType<Map>()) {
            if (part['type'] == 'output_text' || part['type'] == 'refusal') {
              text.write(part['text'] ?? part['refusal'] ?? '');
            }
          }
          replay.add(Map.of(item)..remove('id'));
        case 'function_call' when response['status'] != 'incomplete':
          if (item['call_id'] is! String || item['name'] is! String) break;
          calls.add({
            'id': item['call_id'],
            'type': 'function',
            'function': {
              'name': item['name'],
              'arguments': item['arguments'] ?? '{}',
            },
          });
          replay.add(Map.of(item)..remove('id'));
        case 'reasoning' when item['encrypted_content'] is String:
          replay.add(item);
      }
    }
    if (calls.isNotEmpty)
      _toolOutputByCallId[calls.first['id'] as String] = replay;
    final usage = response['usage'];
    return {
      'id': response['id'],
      'model': response['model'],
      if (usage is Map)
        'usage': {
          ...usage,
          'prompt_tokens': usage['input_tokens'] ?? usage['prompt_tokens'],
          'completion_tokens':
              usage['output_tokens'] ?? usage['completion_tokens'],
        },
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': text.toString(),
            if (calls.isNotEmpty) 'tool_calls': calls,
          },
          'finish_reason': calls.isNotEmpty
              ? 'tool_calls'
              : response['status'] == 'incomplete'
              ? 'length'
              : 'stop',
        },
      ],
    };
  }

  Stream<List<int>> _stream(Stream<List<int>> bytes) async* {
    var streamedText = false;
    final data = <String>[];
    await for (final line
        in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty || data.isEmpty) continue;
      final body = data.join('\n');
      data.clear();
      if (body == '[DONE]') break;
      final event = jsonDecode(body);
      if (event is! Map) continue;
      switch (event['type']) {
        case 'response.output_text.delta':
        case 'response.refusal.delta':
          final delta = event['delta'];
          if (delta is! String || delta.isEmpty) break;
          streamedText = true;
          yield _sse({
            'choices': [
              {
                'delta': {'content': delta},
              },
            ],
          });
        case 'response.completed':
        case 'response.incomplete':
          final completion = _completion(event['response'] as Map);
          final choice = (completion['choices'] as List).single as Map;
          final message = choice['message'] as Map;
          if (!streamedText && (message['content'] as String).isNotEmpty) {
            yield _sse({
              'choices': [
                {
                  'delta': {'content': message['content']},
                },
              ],
            });
          }
          yield _sse(completion);
          return;
        case 'error':
        case 'response.failed':
          final response = event['response'];
          final error = response is Map
              ? response['error']
              : event['error'] ?? event['message'];
          yield _sse({'error': error ?? 'Responses API 返回失败'});
          return;
      }
    }
    throw const FormatException('Responses API 流在收到最终响应前中断');
  }

  List<int> _sse(Map json) => utf8.encode('data: ${jsonEncode(json)}\n\n');

  Future<http.StreamedResponse> send(
    http.Client client,
    http.Request request,
  ) async {
    final response = await client.send(request);
    if (response.statusCode != 200) return response;
    final isStream =
        (response.headers['content-type'] ?? '').contains(
          'text/event-stream',
        ) ||
        (!(response.headers['content-type'] ?? '').contains('json') &&
            (jsonDecode(request.body) as Map)['stream'] == true);
    final headers = Map<String, String>.of(response.headers)
      ..remove('content-length');
    if (isStream) {
      headers['content-type'] = 'text/event-stream';
      return http.StreamedResponse(
        _stream(response.stream),
        200,
        headers: headers,
      );
    }
    final raw = jsonDecode(await response.stream.bytesToString(utf8)) as Map;
    if (raw['error'] != null ||
        raw['status'] == 'failed' ||
        raw['output'] is! List) {
      final error = raw['error'] ?? '服务端没有返回有效的 Responses API 响应';
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'error': error}))),
        502,
        headers: headers,
      );
    }
    headers['content-type'] = 'application/json';
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(_completion(raw)))),
      200,
      headers: headers,
    );
  }
}
