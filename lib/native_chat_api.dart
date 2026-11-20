import 'dart:convert';

import 'package:http/http.dart' as http;

/// Translates the internal chat envelope to the official vendor API.
enum NativeChatApi {
  claude('Claude', 'api.anthropic.com'),
  gemini('Gemini', 'generativelanguage.googleapis.com');

  const NativeChatApi(this.preset, this.host);
  final String preset;
  final String host;

  static NativeChatApi? resolve(Map provider, String url) {
    final uri = Uri.tryParse(url);
    if (provider['is_custom'] == true ||
        uri?.scheme != 'https' ||
        uri?.port != 443 ||
        uri?.userInfo.isNotEmpty == true)
      return null;
    for (final api in values) {
      if (provider['preset_name'] == api.preset && uri?.host == api.host) {
        return api;
      }
    }
    return null;
  }

  Map<String, String> headers(String key) => {
    'Content-Type': 'application/json',
    if (this == claude) ...{
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
    } else
      'x-goog-api-key': key,
  };

  Uri get modelsUrl =>
      Uri.https(host, this == claude ? '/v1/models' : '/v1beta/models');

  Future<List<String>> listModels(String key) async {
    final client = http.Client();
    try {
      final models = <String>{};
      final seen = <String>{};
      var url = modelsUrl;
      while (true) {
        final request = http.Request('GET', url)
          ..followRedirects = false
          ..headers.addAll(headers(key));
        final response = await client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw FormatException('HTTP ${response.statusCode}');
        }
        final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
        for (final row
            in (body[this == claude ? 'data' : 'models'] as List? ?? const [])
                .whereType<Map>()) {
          if (this == gemini &&
              !(row['supportedGenerationMethods'] as List? ?? const [])
                  .contains('generateContent'))
            continue;
          final name = row[this == claude ? 'id' : 'name'];
          if (name is String && name.isNotEmpty)
            models.add(name.replaceFirst(RegExp(r'^models/'), ''));
        }
        final next = this == claude
            ? (body['has_more'] == true ? body['last_id'] : null)
            : body['nextPageToken'];
        if (next is! String || next.isEmpty || !seen.add(next)) break;
        url = modelsUrl.replace(
          queryParameters: {this == claude ? 'after_id' : 'pageToken': next},
        );
      }
      return models.toList()..sort();
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> testConnection(String key, String model) async {
    final started = DateTime.now();
    final client = http.Client();
    try {
      final request = http.Request('POST', modelsUrl)
        ..headers['Authorization'] = 'Bearer $key'
        ..body = jsonEncode({
          'model': model,
          'max_tokens': 256,
          'messages': [
            {'role': 'user', 'content': 'Reply with OK.'},
          ],
        });
      final response = await send(
        client,
        request,
      ).then(http.Response.fromStream).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        return {'passed': false, 'error': 'HTTP ${response.statusCode}'};
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      final content = (body['choices'] as List).first['message']['content'];
      return {
        'passed': content is String && content.trim().isNotEmpty,
        'fastest_latency': DateTime.now().difference(started).inMilliseconds,
      };
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> encode(Map p) {
    final systems = <Map<String, dynamic>>[];
    final contents = <Map<String, dynamic>>[];
    final calls = <String, String>{};
    final geminiCallIds = <String, Object>{};
    final messages = (p['messages'] as List).cast<Map>();
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final role = m['role'];
      final value = m['content'];
      if (role == 'system' && i == 0 && value is String && value.isNotEmpty) {
        systems.add(
          this == claude
              ? {
                  'type': 'text',
                  'text': value,
                  'cache_control': {'type': 'ephemeral'},
                }
              : {'text': value},
        );
        continue;
      }
      final parts = <Map<String, dynamic>>[];
      if (role == 'tool') {
        final id = '${m['tool_call_id']}';
        parts.add(
          this == claude
              ? {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': '${value ?? ''}',
                }
              : {
                  'functionResponse': {
                    'name': calls[id] ?? id,
                    if (geminiCallIds.containsKey(id)) 'id': geminiCallIds[id],
                    'response': {'result': value},
                  },
                },
        );
      } else {
        for (final part
            in value is List
                ? value
                : [
                    {'type': 'text', 'text': value},
                  ]) {
          if (part is! Map) continue;
          if (part['type'] == 'text' && '${part['text'] ?? ''}'.isNotEmpty) {
            final text = role == 'system' || role == 'developer'
                ? '【本轮附加上下文】\n${part['text']}'
                : '${part['text']}';
            parts.add(
              this == claude ? {'type': 'text', 'text': text} : {'text': text},
            );
          } else if (part['type'] == 'image_url') {
            final url = '${(part['image_url'] as Map)['url']}';
            final match = RegExp(r'^data:([^;]+);base64,(.+)$').firstMatch(url);
            if (match != null) {
              parts.add(
                this == claude
                    ? {
                        'type': 'image',
                        'source': {
                          'type': 'base64',
                          'media_type': match[1],
                          'data': match[2],
                        },
                      }
                    : {
                        'inlineData': {'mimeType': match[1], 'data': match[2]},
                      },
              );
            } else if (this == claude) {
              parts.add({
                'type': 'image',
                'source': {'type': 'url', 'url': url},
              });
            } else {
              throw const FormatException('Gemini requires inline image data');
            }
          } else if (part['type'] == 'input_audio') {
            if (this == claude)
              throw const FormatException(
                'Claude Messages does not accept audio input',
              );
            final audio = part['input_audio'] as Map;
            parts.add({
              'inlineData': {
                'mimeType': 'audio/${audio['format']}',
                'data': audio['data'],
              },
            });
          }
        }
        for (final call in (m['tool_calls'] as List? ?? const []).cast<Map>()) {
          final f = call['function'] as Map;
          final name = '${f['name']}';
          final id = '${call['id']}';
          calls[id] = name;
          if (call['native_function_id'] case final String nativeId) {
            geminiCallIds[id] = nativeId;
          }
          final rawArgs = '${f['arguments'] ?? ''}';
          final args = rawArgs.trim().isEmpty
              ? <String, dynamic>{}
              : jsonDecode(rawArgs);
          parts.add(
            this == claude
                ? {'type': 'tool_use', 'id': id, 'name': name, 'input': args}
                : {
                    'functionCall': {
                      'name': name,
                      'args': args,
                      if (geminiCallIds.containsKey(id))
                        'id': geminiCallIds[id],
                    },
                    if (call['native_thought_signature'] != null)
                      'thoughtSignature': call['native_thought_signature'],
                  },
          );
        }
      }
      if (parts.isEmpty) continue;
      final wireRole = role == 'assistant'
          ? (this == claude ? 'assistant' : 'model')
          : 'user';
      final field = this == claude ? 'content' : 'parts';
      if (contents.isNotEmpty && contents.last['role'] == wireRole) {
        (contents.last[field] as List).addAll(parts);
      } else {
        contents.add({'role': wireRole, field: parts});
      }
    }
    final functions = [
      for (final tool in (p['tools'] as List? ?? const []).cast<Map>())
        tool['function'] as Map,
    ];
    final selection = p['tool_choice'];
    final function = selection is Map ? selection['function'] : null;
    final forced = function is Map ? function['name'] : null;
    if (this == claude) {
      return {
        'model': p['model'],
        if (functions.isNotEmpty && forced != null)
          'tool_choice': {'type': 'tool', 'name': forced},
        'max_tokens': (p['max_tokens'] as int? ?? 4096).clamp(1, 4096),
        'messages': contents,
        if (systems.isNotEmpty) 'system': systems,
        if (p['stream'] == true) 'stream': true,
        if (functions.isNotEmpty)
          'tools': [
            for (final f in functions)
              {
                'name': f['name'],
                'description': f['description'] ?? '',
                'input_schema': f['parameters'] ?? {'type': 'object'},
              },
          ],
      };
    }
    return {
      'contents': contents,
      if (p['max_tokens'] != null || p['temperature'] != null)
        'generationConfig': {
          if (p['max_tokens'] case final int limit)
            'maxOutputTokens': limit.clamp(1, 8192),
          if (p['temperature'] != null) 'temperature': p['temperature'],
        },
      if (functions.isNotEmpty && forced != null)
        'toolConfig': {
          'functionCallingConfig': {
            'mode': 'ANY',
            'allowedFunctionNames': [forced],
          },
        },
      if (systems.isNotEmpty) 'systemInstruction': {'parts': systems},
      if (functions.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final f in functions)
                {
                  'name': f['name'],
                  'description': f['description'] ?? '',
                  if (f['parameters'] != null)
                    'parametersJsonSchema': f['parameters'],
                },
            ],
          },
        ],
    };
  }

  Map usage(Map raw) {
    if (this == gemini) {
      return {
        'prompt_tokens': raw['promptTokenCount'],
        'completion_tokens':
            (raw['candidatesTokenCount'] as int? ?? 0) +
            (raw['thoughtsTokenCount'] as int? ?? 0),
        'total_tokens': raw['totalTokenCount'],
        if (raw['cachedContentTokenCount'] != null)
          'prompt_tokens_details': {
            'cached_tokens': raw['cachedContentTokenCount'],
          },
      };
    }
    final read = raw['cache_read_input_tokens'];
    final written = raw['cache_creation_input_tokens'];
    final input = raw['input_tokens'];
    final output = raw['output_tokens'];
    return {
      if (input is num)
        'prompt_tokens': input + (read as num? ?? 0) + (written as num? ?? 0),
      if (output != null) 'completion_tokens': output,
      if (read != null) 'prompt_tokens_details': {'cached_tokens': read},
      if (read != null) 'cache_read_input_tokens': read,
      if (written != null) 'cache_creation_input_tokens': written,
    };
  }

  Map<String, dynamic> _delta(Map delta, {String? finish, Map? stats}) => {
    'choices': [
      {'index': 0, 'delta': delta, if (finish != null) 'finish_reason': finish},
    ],
    if (stats != null) 'usage': stats,
  };

  Map<String, dynamic> _call(
    int index,
    String id,
    Map f, {
    Object? signature,
    Object? nativeFunctionId,
  }) => {
    'index': index,
    'id': id,
    'type': 'function',
    'function': f,
    if (signature != null) 'native_thought_signature': signature,
    if (nativeFunctionId != null) 'native_function_id': nativeFunctionId,
  };

  List<Map<String, dynamic>> _geminiChunks(
    Map data,
    int Function() nextCall,
    String id,
  ) {
    final result = <Map<String, dynamic>>[];
    if (data['error'] != null)
      throw const FormatException('Gemini generation error');
    if ((data['promptFeedback'] as Map?)?['blockReason'] != null) {
      throw const FormatException('Gemini blocked the prompt');
    }
    final candidates = data['candidates'] as List? ?? const [];
    if (candidates.any(
      (c) =>
          c is Map &&
          const {
            'SAFETY',
            'RECITATION',
            'MALFORMED_FUNCTION_CALL',
            'PROHIBITED_CONTENT',
          }.contains(c['finishReason']),
    )) {
      throw const FormatException('Gemini could not complete generation');
    }
    for (final candidate in candidates.take(1).cast<Map>()) {
      for (final part
          in ((candidate['content'] as Map?)?['parts'] as List? ?? const [])
              .cast<Map>()) {
        if (part['thought'] == true) continue;
        if (part['text'] is String)
          result.add(_delta({'content': part['text']}));
        if (part['functionCall'] case final Map f) {
          final index = nextCall();
          result.add(
            _delta({
              'tool_calls': [
                _call(
                  index,
                  '${id}_$index',
                  {'name': f['name'], 'arguments': jsonEncode(f['args'] ?? {})},
                  signature: part['thoughtSignature'],
                  nativeFunctionId: f['id'],
                ),
              ],
            }),
          );
        }
      }
    }
    if (data['usageMetadata'] case final Map raw)
      result.add(_delta({}, stats: usage(raw)));
    return result;
  }

  Future<http.StreamedResponse> send(
    http.Client client,
    http.Request request,
  ) async {
    final p = jsonDecode(request.body) as Map;
    final model = '${p['model']}'.replaceFirst(RegExp(r'^models/'), '');
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(model))
      throw const FormatException('Invalid native chat model ID');
    final stream = p['stream'] == true;
    final url = this == claude
        ? Uri.https(host, '/v1/messages')
        : Uri.https(
            host,
            '/v1beta/models/$model:${stream ? 'streamGenerateContent' : 'generateContent'}',
            stream ? {'alt': 'sse'} : null,
          );
    final key = (request.headers['Authorization'] ?? '').replaceFirst(
      'Bearer ',
      '',
    );
    final native = http.Request('POST', url)
      ..headers.addAll(headers(key))
      ..body = jsonEncode(encode(p));
    native.followRedirects = false;
    final response = await client.send(native);
    if (response.statusCode != 200) return response;
    final id = 'native_${DateTime.now().microsecondsSinceEpoch}';
    var index = 0;
    final outputHeaders = {...response.headers}
      ..remove('content-length')
      ..remove('content-encoding');
    if (!stream) {
      final data =
          jsonDecode(await response.stream.transform(utf8.decoder).join())
              as Map;
      final text = StringBuffer();
      final tools = <Map>[];
      Map? stats;
      if (this == claude) {
        for (final part in (data['content'] as List? ?? const []).cast<Map>()) {
          if (part['type'] == 'text') text.write(part['text']);
          if (part['type'] == 'tool_use')
            tools.add(
              _call(index++, '${part['id']}', {
                'name': part['name'],
                'arguments': jsonEncode(part['input']),
              }),
            );
        }
        stats = usage(data['usage'] as Map? ?? {});
      } else {
        for (final chunk in _geminiChunks(data, () => index++, id)) {
          final delta = (chunk['choices'] as List).first['delta'] as Map;
          text.write(delta['content'] ?? '');
          tools.addAll((delta['tool_calls'] as List? ?? const []).cast<Map>());
          stats = chunk['usage'] as Map? ?? stats;
        }
      }
      final body = jsonEncode({
        'id': data['id'] ?? id,
        'model': data['model'] ?? data['modelVersion'],
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': text.toString(),
              if (tools.isNotEmpty) 'tool_calls': tools,
            },
            'finish_reason': tools.isEmpty ? 'stop' : 'tool_calls',
          },
        ],
        if (stats != null) 'usage': stats,
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: outputHeaders,
      );
    }
    Stream<List<int>> events() async* {
      final rawUsage = <String, dynamic>{};
      var hasTools = false;
      var completed = false;
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final json = line.substring(5).trim();
        if (json.isEmpty || json == '[DONE]') continue;
        final data = jsonDecode(json) as Map;
        final chunks = <Map<String, dynamic>>[];
        if (this == gemini) {
          chunks.addAll(_geminiChunks(data, () => index++, id));
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final reason = (candidates.first as Map)['finishReason'];
            if (reason != null && reason != 'FINISH_REASON_UNSPECIFIED')
              completed = true;
          }
        } else {
          final blockIndex = data['index'] as int? ?? 0;
          switch (data['type']) {
            case 'message_start':
              rawUsage.addAll(
                Map<String, dynamic>.from(
                  (data['message'] as Map)['usage'] as Map? ?? {},
                ),
              );
            case 'content_block_start':
              final block = data['content_block'] as Map;
              if (block['type'] == 'tool_use')
                chunks.add(
                  _delta({
                    'tool_calls': [
                      _call(blockIndex, '${block['id']}', {
                        'name': block['name'],
                        'arguments': '',
                      }),
                    ],
                  }),
                );
              if (block['type'] == 'text' &&
                  '${block['text'] ?? ''}'.isNotEmpty)
                chunks.add(_delta({'content': block['text']}));
            case 'content_block_delta':
              final delta = data['delta'] as Map;
              if (delta['type'] == 'text_delta')
                chunks.add(_delta({'content': delta['text']}));
              if (delta['type'] == 'input_json_delta')
                chunks.add(
                  _delta({
                    'tool_calls': [
                      {
                        'index': blockIndex,
                        'function': {'arguments': delta['partial_json']},
                      },
                    ],
                  }),
                );
            case 'message_stop':
              completed = true;
            case 'message_delta':
              rawUsage.addAll(
                Map<String, dynamic>.from(data['usage'] as Map? ?? {}),
              );
            case 'error':
              throw const FormatException('Anthropic streaming error');
          }
        }
        for (final chunk in chunks) {
          if ((chunk['choices'] as List).first['delta']['tool_calls'] != null)
            hasTools = true;
          yield utf8.encode('data: ${jsonEncode({'id': id, ...chunk})}\n\n');
        }
      }
      if (!completed)
        throw const FormatException('Incomplete native chat stream');
      yield utf8.encode(
        'data: ${jsonEncode(_delta({}, finish: hasTools ? 'tool_calls' : 'stop', stats: this == claude ? usage(rawUsage) : null))}\n\ndata: [DONE]\n\n',
      );
    }

    return http.StreamedResponse(events(), 200, headers: outputHeaders);
  }
}
