import 'dart:convert';
import 'dart:io';

import 'package:skytide/chat_attachment_access.dart';
import 'package:skytide/chat_file_transport.dart';
import 'package:skytide/chat_gpt_responses.dart';
import 'package:skytide/chat_protocol.dart';
import 'package:skytide/native_chat_api.dart';

void check(bool result, String reason) {
  if (!result) throw StateError(reason);
}

Future<void> reject(Future<Object> Function() action, String reason) async {
  try {
    await action();
  } on FormatException {
    return;
  }
  throw StateError(reason);
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('chat_attachment_');
  try {
    final pdf = File('${directory.path}/报告.v2.PDF');
    final bytes = [37, 80, 68, 70, 45, 0, 255];
    await pdf.writeAsBytes(bytes);
    final catalog = ChatAttachmentCatalog();
    catalog.add({
      'id': 'plugin_doc',
      'role': 'assistant',
      'type': 'document',
      'file_path': pdf.path,
    });
    catalog.add({
      'id': 'plugin_video',
      'role': 'assistant',
      'type': 'video',
      'file_path': '/managed/video.mp4',
    });
    catalog.add({
      'id': 'plugin_failed',
      'role': 'assistant',
      'type': 'file',
      'file_path': '/managed/not-sent.pdf',
      'error_code': 'failed',
    });
    final reference = catalog.filesByMessageId['plugin_doc']!;
    check(reference.label == '[文件#1] 报告.v2.PDF', 'original label');
    check(catalog.filesByMessageId.length == 1, 'failed attachment excluded');
    check(
      catalog.pluginVideoPaths['VID-plugin_video'] == '/managed/video.mp4',
      'stable video lookup',
    );

    ChatFileTransport transport(ChatFileProtocol protocol) => ChatFileTransport(
      protocol,
      baseUrl: 'https://example.test/v1',
      apiKey: 'test-key',
    );
    final original = await transport(
      ChatFileProtocol.openAIResponses,
    ).attach(reference);
    final encoded = base64Encode(bytes);
    check(
      original['file_data'] == 'data:application/pdf;base64,$encoded',
      'original binary data',
    );
    final schema = readChatFileToolSchema()['function'] as Map;
    check(
      schema['name'] == 'read_chat_file' &&
          (schema['parameters']['properties'] as Map).keys.single ==
              'file_number',
      'no path parameter',
    );

    final payload = <String, dynamic>{
      'model': 'mock',
      'messages': [
        {'role': 'user', 'content': '读取 ${reference.label}'},
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'id': 'call_file',
              'function': {
                'name': 'read_chat_file',
                'arguments': '{"file_number":1}',
              },
            },
            {
              'id': 'call_other',
              'function': {'name': 'lookup', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_file', 'content': '{"ok":true}'},
        {
          'role': 'tool',
          'tool_call_id': 'call_other',
          'content': '{"ok":true}',
        },
        {
          'role': 'user',
          'content': [original],
        },
      ],
    };
    final openAi = ChatGptResponses('test').payload(payload)['input'] as List;
    check(
      openAi[openAi.length - 2]['type'] == 'function_call_output',
      'outputs precede attachments',
    );
    final openAiFile = openAi.last['content'].last;
    check(
      openAiFile['type'] == 'input_file' &&
          openAiFile['filename'] == reference.name &&
          openAiFile['file_data'] == original['file_data'],
      'Responses wire file',
    );
    final claude = NativeChatApi.claude.encode(payload);
    final claudeParts = claude['messages'].last['content'] as List;
    check(
      claudeParts[0]['type'] == 'tool_result' &&
          claudeParts[1]['type'] == 'tool_result' &&
          claudeParts.last['type'] == 'document',
      'Claude tool outputs and document order',
    );
    check(
      claudeParts.last['title'] == reference.name &&
          claudeParts.last['source']['data'] == encoded,
      'Claude wire file',
    );
    final gemini = NativeChatApi.gemini.encode(payload);
    final geminiParts = gemini['contents'].last['parts'] as List;
    check(
      geminiParts[0]['functionResponse']['name'] == 'read_chat_file' &&
          geminiParts.last['inlineData']['data'] == encoded,
      'Gemini wire file',
    );
    check(
      !jsonEncode([openAi, claude, gemini]).contains(pdf.path),
      'local path must not be uploaded',
    );

    await reject(
      () => readChatFileBytes(reference, remainingBytes: bytes.length - 1),
      'file budget',
    );
    await reject(
      () => transport(ChatFileProtocol.unsupported).attach(reference),
      'unsupported API',
    );
    await pdf.delete();
    await reject(
      () => transport(ChatFileProtocol.claude).attach(reference),
      'missing original',
    );
    print('Chat attachment checks passed.');
  } finally {
    await directory.delete(recursive: true);
  }
}
