import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/chat_attachment_access.dart';
import 'package:skytide/chat_file_capability.dart';
import 'package:skytide/chat_file_transport.dart';
import 'package:skytide/chat_gpt_responses.dart';

import 'chat_attachment_check.dart' show check;

const _url = 'https://example.test/v1';
const _json = {'content-type': 'application/json'};
const _sse = {'content-type': 'text/event-stream'};
const _rejection =
    '{"error":{"message":"This model does not support input_file"}}';

ChatFileTransport transport(ChatFileProtocol protocol) =>
    ChatFileTransport(protocol, baseUrl: _url, apiKey: 'test');

String wire(List<Map<String, dynamic>> messages) =>
    jsonEncode({'messages': messages});

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'chat_file_fallback_',
  );
  try {
    final file = await File(
      '${directory.path}/报告.pdf',
    ).writeAsString('%PDF-test');
    final reference = ChatFileReference(1, file.path);
    final second = ChatFileReference(2, file.path);
    var extracted = 0;
    Future<String> extract(String path) async {
      check(path == file.path, 'extract the catalog file');
      extracted++;
      return '提取的正文';
    }

    final unsupported = transport(ChatFileProtocol.unsupported);
    final onlyText = <String, dynamic>{'role': 'user', 'content': '问题'};
    await unsupported.attachToUserMessage(onlyText, [
      reference,
    ], extract: extract);
    check(
      onlyText['content'].contains('仅提取文本') &&
          !unsupported.hasRawAttachments &&
          extracted == 1,
      'unsupported preset immediately extracts',
    );
    final custom = transport(ChatFileProtocol.openAIChat);
    final user = <String, dynamic>{
      'role': 'user',
      'content': [
        {'type': 'text', 'text': '用户问题'},
        {
          'type': 'image_url',
          'image_url': {'url': 'image-test'},
        },
      ],
    };
    final messages = [user];
    await custom.attachToUserMessage(user, [reference], extract: extract);
    check(
      extracted == 1 && custom.hasRawAttachments,
      'raw attachment precedes extraction',
    );
    var sends = 0;
    final client = MockClient((request) async {
      sends++;
      check(
        request.body.contains('用户问题') && request.body.contains('image-test'),
        'user input and image are preserved',
      );
      if (sends == 1) {
        check(
          request.body.contains('file_data') && !request.body.contains('提取的正文'),
          'first attempt carries raw bytes only',
        );
        return http.Response(_rejection, 422, headers: _json);
      }
      check(
        !request.body.contains('file_data') &&
            request.body.contains('提取的正文') &&
            request.body.contains('仅提取文本'),
        'second attempt carries labeled text only',
      );
      return http.Response('{"ok":true}', 200, headers: _json);
    });
    final response = await custom.sendWithTextFallback(
      client: client,
      messages: messages,
      extract: extract,
      send: (c) => c.send(
        http.Request('POST', Uri.parse('$_url/chat/completions'))
          ..body = wire(messages),
      ),
    );
    check(
      await response.stream.bytesToString() == '{"ok":true}' &&
          sends == 2 &&
          extracted == 2,
      'retry exactly once after rejection',
    );
    final laterPart = await custom.attachWithTextFallback(
      second,
      extract: extract,
    );
    check(
      laterPart['type'] == 'text' && extracted == 3,
      'later attachments in the same chain use text',
    );
    client.close();

    await checkRawSuccess(reference);
    await checkToolContinuation(reference, extract);
    await checkQwen(reference, extract);
    await checkGrokRoute(reference, extract);
    await checkUploadRejection(reference, extract);
    await checkErrorsAndStreams();
    print('chat_file_fallback_check: OK');
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> checkRawSuccess(ChatFileReference reference) async {
  final files = transport(ChatFileProtocol.openAIChat);
  final user = <String, dynamic>{'role': 'user', 'content': '读取附件'};
  final messages = [user];
  Future<String> extract(String _) async =>
      throw StateError('unexpected extraction');
  await files.attachToUserMessage(user, [reference], extract: extract);
  var sends = 0;
  const body =
      '{"choices":[{"message":{"content":"The PDF does not support editing"}}]}';
  final client = MockClient((request) async {
    sends++;
    check(
      request.body.contains('file_data'),
      'successful request carries raw file',
    );
    return http.Response(body, 200, headers: _json);
  });
  final response = await files.sendWithTextFallback(
    client: client,
    messages: messages,
    extract: extract,
    send: (c) => c.send(
      http.Request('POST', Uri.parse('$_url/chat/completions'))
        ..body = wire(messages),
    ),
  );
  check(
    await response.stream.bytesToString() == body &&
        sends == 1 &&
        files.hasRawAttachments,
    'successful JSON replayed unmodified without extraction',
  );
  client.close();
}

Future<void> checkToolContinuation(
  ChatFileReference reference,
  Future<String> Function(String) extract,
) async {
  final files = transport(ChatFileProtocol.openAIResponses);
  final toolOutput = {
    'role': 'tool',
    'tool_call_id': 'call_test',
    'content': '{"ok":true}',
  };
  final messages = <Map<String, dynamic>>[
    {'role': 'user', 'content': '请读取历史附件'},
    {
      'role': 'assistant',
      'tool_calls': [
        {
          'id': 'call_test',
          'type': 'function',
          'function': {
            'name': 'read_chat_file',
            'arguments': '{"file_number":1}',
          },
        },
      ],
    },
    toolOutput,
  ];
  final user = <String, dynamic>{'role': 'user', 'content': ''};
  await files.attachToUserMessage(user, [reference], extract: extract);
  messages.add(user);
  final responses = ChatGptResponses('test');
  var sends = 0;
  final client = MockClient((request) async {
    sends++;
    final items = (jsonDecode(request.body) as Map)['input'] as List;
    check(
      items.where((item) => item['type'] == 'function_call_output').length == 1,
      'tool result stays intact on both sends',
    );
    if (sends == 1) return http.Response(_rejection, 400, headers: _json);
    check(
      request.body.contains('提取的正文') && !request.body.contains('file_data'),
      'tool continuation retries in the same protocol',
    );
    return http.Response(_rejection, 400, headers: _json);
  });
  final result = await files.sendWithTextFallback(
    client: client,
    messages: messages,
    extract: extract,
    send: (c) => responses.send(
      c,
      http.Request('POST', ChatGptResponses.endpoint(_url))
        ..body = jsonEncode(
          responses.payload({'model': 'test', 'messages': messages}),
        ),
    ),
  );
  await result.stream.drain<void>();
  check(
    result.statusCode == 400 &&
        sends == 2 &&
        identical(messages[2], toolOutput),
    'no further retries and same tool result object',
  );
  client.close();
}

Future<void> checkQwen(
  ChatFileReference ref,
  Future<String> Function(String) extract,
) async {
  final files = transport(ChatFileProtocol.qwenLong);
  final user = <String, dynamic>{'role': 'user', 'content': '阅读文档'};
  final messages = [user];
  var sends = 0;
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/files'))
      return http.Response('{"id":"qwen-test"}', 200, headers: _json);
    if (request.method == 'DELETE') {
      check(
        request.url.path.endsWith('/files/qwen-test'),
        'clean up Qwen upload after fallback',
      );
      return http.Response('', 204);
    }
    sends++;
    if (sends == 1) {
      check(
        messages[1]['content'] == 'fileid://qwen-test',
        'send Qwen reference once',
      );
      return http.Response(_rejection, 400, headers: _json);
    }
    check(
      !request.body.contains('fileid://') &&
          user['content'].contains('阅读文档') &&
          user['content'].contains('提取的正文'),
      'remove Qwen system reference but preserve the user prompt',
    );
    return http.Response('{}', 200, headers: _json);
  });
  await files.attachToUserMessage(
    user,
    [ref],
    extract: extract,
    upload: (action) => action(client),
  );
  files.addQwenReferences(messages);
  final result = await files.sendWithTextFallback(
    client: client,
    messages: messages,
    extract: extract,
    send: (c) => c.send(
      http.Request('POST', Uri.parse('$_url/chat/completions'))
        ..body = wire(messages),
    ),
  );
  await result.stream.drain<void>();
  check(sends == 2, 'Qwen retries once');
  await files.close(createClient: () => client);
}

Future<void> checkGrokRoute(
  ChatFileReference ref,
  Future<String> Function(String) extract,
) async {
  final files = transport(ChatFileProtocol.grok);
  final user = <String, dynamic>{'role': 'user', 'content': '读附件'};
  final messages = [user];
  var responses = true;
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/files'))
      return http.Response('{"id":"xai-test"}', 200, headers: _json);
    if (request.url.path.endsWith('/responses')) {
      check(request.body.contains('xai-test'), 'Grok attempts the file route');
      return http.Response('404 page not found', 404);
    }
    check(
      request.url.path.endsWith('/chat/completions') &&
          request.body.contains('提取的正文') &&
          !request.body.contains('xai-test'),
      'missing Grok Responses route falls back to Chat Completions',
    );
    return http.Response('{}', 200, headers: _json);
  });
  await files.attachToUserMessage(
    user,
    [ref],
    extract: extract,
    upload: (action) => action(client),
  );
  final result = await files.sendWithTextFallback(
    client: client,
    messages: messages,
    extract: extract,
    onMissingEndpoint: () => responses = false,
    send: (c) => c.send(
      http.Request(
        'POST',
        Uri.parse('$_url/${responses ? 'responses' : 'chat/completions'}'),
      )..body = wire(messages),
    ),
  );
  await result.stream.drain<void>();
  check(result.statusCode == 200 && !responses, 'Grok route changed');
  client.close();
}

Future<void> checkUploadRejection(
  ChatFileReference ref,
  Future<String> Function(String) extract,
) async {
  for (final (status, body, fallback) in [
    (415, '{"error":{"code":"unsupported_file_type"}}', true),
    (
      422,
      '{"detail":[{"loc":["body","file"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}',
      true,
    ),
    (404, '404 page not found', true),
    (403, _rejection, false),
    (404, '{"error":{"code":"model_not_found"}}', false),
    (429, _rejection, false),
  ]) {
    final files = transport(ChatFileProtocol.grok);
    var uploads = 0;
    var extractions = 0;
    final client = MockClient((request) async {
      uploads++;
      check(
        request.method == 'POST' && request.url.path.endsWith('/files'),
        'try the upload endpoint first',
      );
      return http.Response(body, status, headers: _json);
    });
    try {
      final part = await files.attachWithTextFallback(
        ref,
        extract: (path) {
          extractions++;
          return extract(path);
        },
        upload: (action) => action(client),
      );
      check(
        fallback &&
            part['type'] == 'text' &&
            (part['text'] as String).contains('仅提取文本'),
        'upload rejection produces labeled text for HTTP $status',
      );
    } on FormatException catch (error) {
      check(
        !fallback &&
            error is! ChatFileUnsupported &&
            error.message == '原文件上传失败（HTTP $status）',
        'unrelated upload errors propagate without exposing the body',
      );
    } finally {
      client.close();
    }
    check(
      uploads == 1 &&
          extractions == (fallback ? 1 : 0) &&
          !files.hasRawAttachments,
      'no upload retry or stale file reference',
    );
  }
}

Future<void> checkErrorsAndStreams() async {
  final url = Uri.parse('$_url/responses');
  for (final (status, body) in [
    (400, '{"error":{"message":"context length exceeded"}}'),
    (
      400,
      '{"error":{"code":"permission_denied","message":"This API key does not support file uploads"}}',
    ),
    (401, _rejection),
    (403, _rejection),
    (429, _rejection),
    (503, _rejection),
    (404, '{"error":{"code":"model_not_found","message":"model not found"}}'),
  ]) {
    final client = MockClient(
      (_) async => http.Response(body, status, headers: _json),
    );
    final result = await ChatFileCapabilityClient(
      client,
      allowMissingEndpoint: true,
    ).send(http.Request('POST', url));
    check(
      result.statusCode == status &&
          await result.stream.bytesToString() == body,
      'preserve unrelated HTTP $status',
    );
    client.close();
  }
  final denied = MockClient.streaming(
    (_, __) async => http.StreamedResponse(
      Stream.fromIterable([
        utf8.encode('data: {"type":"response.created"}\n\nevent: error\nda'),
        utf8.encode('ta: $_rejection\n\n'),
      ]),
      200,
      headers: _sse,
    ),
  );
  try {
    await ChatFileCapabilityClient(denied).send(http.Request('POST', url));
    throw StateError('expected multipart SSE rejection');
  } on ChatFileUnsupported {
    // Rejection was detected before any preview delta could be emitted.
  } finally {
    denied.close();
  }
  final cancelled = Completer<void>();
  final controller = StreamController<List<int>>(
    onCancel: () => cancelled.complete(),
  );
  const first = 'data: {"choices":[{"delta":{"content":"可读"}}]}\n\n';
  controller.add(utf8.encode(first));
  final ok = MockClient.streaming(
    (_, __) async =>
        http.StreamedResponse(controller.stream, 200, headers: _sse),
  );
  final stream = await ChatFileCapabilityClient(
    ok,
  ).send(http.Request('POST', url));
  check(
    utf8.decode(await stream.stream.first) == first,
    'first visible SSE bytes replayed unchanged',
  );
  await cancelled.future.timeout(const Duration(seconds: 2));
  await controller.close();
  ok.close();
}
