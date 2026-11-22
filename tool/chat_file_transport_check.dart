import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skytide/chat_attachment_access.dart';
import 'package:skytide/chat_file_transport.dart';
import 'package:skytide/chat_gpt_responses.dart';
import 'package:skytide/chat_provider_cache.dart';

import 'chat_attachment_check.dart' show check, reject;

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('chat_file_transport_');
  try {
    final raw = [37, 80, 68, 70, 45, 0, 255];
    final pdf = await File('${dir.path}/报告.v2.PDF').writeAsBytes(raw);
    final reference = ChatFileReference(1, pdf.path);
    ChatFileTransport transport(
      ChatFileProtocol protocol, [
      String url = 'https://example.test/gateway/v1',
    ]) => ChatFileTransport(protocol, baseUrl: url, apiKey: 'test-key');

    final custom = transport(ChatFileProtocol.openAIChat);
    final user = <String, dynamic>{
      'role': 'user',
      'content': [
        {'type': 'text', 'text': reference.label},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,AA=='},
        },
      ],
    };
    await custom.attachToUserMessage(user, [reference]);
    final mixed = user['content'] as List;
    check(
      mixed.length == 3 && mixed[1]['type'] == 'image_url',
      'mixed first round',
    );
    final openAiFile = mixed.last['file'];
    check(
      openAiFile['filename'] == reference.name &&
          openAiFile['file_data'] ==
              'data:application/pdf;base64,${base64Encode(raw)}' &&
          custom.contains(reference.number),
      'compatible payload and shared delivery state',
    );
    final onlyFile = <String, dynamic>{'role': 'user', 'content': ''};
    await transport(
      ChatFileProtocol.gemini,
    ).attachToUserMessage(onlyFile, [reference]);
    check(
      onlyFile['content'].single['type'] == 'input_file',
      'file-only first round',
    );

    final customPreset = ChatProviderCache.resolve({
      'preset_name': 'Grok',
      'is_custom': true,
    });
    check(
      ChatFileProtocol.resolve(customPreset, 'grok', null) ==
          ChatFileProtocol.openAIChat,
      'custom configuration does not use vendor upload',
    );
    check(
      ChatFileProtocol.resolve(ChatProviderCache.gitee, 'model', null) ==
          ChatFileProtocol.openAIChat,
      'Moark Chat Completions declares a file content block',
    );
    for (final provider in [
      ChatProviderCache.mimo,
      ChatProviderCache.miniMax,
      ChatProviderCache.siliconFlow,
      ChatProviderCache.kimi,
    ]) {
      check(
        ChatFileProtocol.resolve(provider, 'model', null) ==
            ChatFileProtocol.unsupported,
        'unsupported preset: $provider',
      );
    }
    check(
      ChatFileProtocol.resolve(
            ChatProviderCache.deepSeek,
            'deepseek-v4-pro',
            null,
          ) ==
          ChatFileProtocol.unsupported,
      'DeepSeek model restriction',
    );
    check(
      ChatFileProtocol.resolve(
            ChatProviderCache.deepSeek,
            'deepseek-flash',
            null,
          ) ==
          ChatFileProtocol.deepSeek,
      'DeepSeek native routing',
    );
    check(
      ChatFileProtocol.resolve(
            ChatProviderCache.dashScope,
            'qwen-long',
            null,
          ) ==
          ChatFileProtocol.qwenLong,
      'Qwen-Long native routing',
    );

    var uploaded = 0;
    ChatFileUpload uploader(String url, String purpose, {int status = 200}) =>
        (action) async {
          final client = MockClient((request) async {
            check(
              request.url.toString() == url && request.method == 'POST',
              'files endpoint',
            );
            check(
              request.headers['authorization'] == 'Bearer test-key',
              'provider authorization',
            );
            final body = latin1.decode(request.bodyBytes);
            final binary = latin1.decode(raw);
            check(
              body.contains(purpose) && body.contains(binary),
              'multipart purpose and raw bytes',
            );
            check(
              body.indexOf(purpose) < body.indexOf(binary),
              'multipart field order',
            );
            check(!body.contains(dir.path), 'no local path in upload');
            return http.Response('{"id":"file-test-${++uploaded}"}', status);
          });
          try {
            return await action(client);
          } finally {
            client.close();
          }
        };
    const gatewayFiles = 'https://example.test/gateway/v1/files';
    final grok = transport(ChatFileProtocol.grok);
    final grokPart = await grok.attach(
      reference,
      upload: uploader(gatewayFiles, 'assistants'),
    );
    final grokWire = ChatGptResponses('test', grok: true).payload({
      'model': 'grok',
      'messages': [
        {'role': 'tool', 'tool_call_id': 'test-call', 'content': '{"ok":true}'},
        {
          'role': 'user',
          'content': [grokPart],
        },
      ],
    });
    final input = grokWire['input'] as List;
    check(
      input.first['type'] == 'function_call_output' &&
          input.last['content'].single['file_id'] == 'file-test-1' &&
          !grokWire.containsKey('prompt_cache_key'),
      'Grok tool continuation with Files API reference',
    );
    final deepSeek = transport(
      ChatFileProtocol.deepSeek,
      'https://api.deepseek.com/v1',
    );
    final deepPart = await deepSeek.attach(
      reference,
      upload: uploader(
        'https://api.deepseek.com/files',
        'rich_layout_recognition',
      ),
    );
    check(
      deepPart['type'] == 'file' &&
          deepPart['file_id'] == 'file-test-2' &&
          deepPart.length == 2,
      'DeepSeek top-level file_id',
    );
    final qwen = transport(ChatFileProtocol.qwenLong);
    final qwenUser = <String, dynamic>{'role': 'user', 'content': '阅读附件'};
    await qwen.attachToUserMessage(qwenUser, [
      reference,
      ChatFileReference(2, pdf.path),
    ], upload: uploader(gatewayFiles, 'file-extract'));
    final qwenMessages = [qwenUser];
    qwen.addQwenReferences(qwenMessages);
    check(
      qwenMessages[1]['content'] ==
              'fileid://file-test-3,fileid://file-test-4' &&
          qwenUser['content'] == '阅读附件',
      'Qwen document references',
    );
    final legacyDoc = await File('${dir.path}/legacy.doc').writeAsBytes(raw);
    await reject(
      () => qwen.attach(ChatFileReference(3, legacyDoc.path)),
      'Qwen rejects undocumented legacy Word format before upload',
    );
    final deleted = <String>[];
    final cleanup = MockClient((request) async {
      check(request.method == 'DELETE', 'Qwen cleanup uses DELETE');
      check(
        request.headers['authorization'] == 'Bearer test-key',
        'Qwen cleanup uses the upload authorization',
      );
      deleted.add(request.url.toString());
      return http.Response('{}', 200);
    });
    await qwen.close(createClient: () => cleanup);
    await qwen.close(createClient: () => throw StateError('cleanup repeated'));
    check(
      deleted.length == 2 &&
          deleted.contains('$gatewayFiles/file-test-3') &&
          deleted.contains('$gatewayFiles/file-test-4'),
      'Qwen cleanup deletes each uploaded ID once under the configured base URL',
    );
    final failed = transport(ChatFileProtocol.grok);
    await reject(
      () => failed.attach(
        reference,
        upload: uploader(gatewayFiles, 'assistants', status: 400),
      ),
      'rejected upload',
    );
    check(!failed.hasAttachments, 'rejected upload is not marked attached');
    await reject(
      () => failed.attach(
        reference,
        upload: (_) async =>
            throw const FormatException('simulated cancellation'),
      ),
      'interrupted upload',
    );
    check(!failed.hasAttachments, 'interrupted upload is not marked attached');
    final retried = await failed.attach(
      reference,
      upload: uploader(gatewayFiles, 'assistants'),
    );
    check(
      failed.contains(reference.number) && retried['file_id'] != null,
      'retry sends the raw file after an interrupted upload',
    );
    print('Chat file transport checks passed.');
  } finally {
    await dir.delete(recursive: true);
  }
}
