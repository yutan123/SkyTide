import 'dart:convert';

import 'package:skytide/chat_content.dart';
import 'package:skytide/diary_output.dart';
import 'package:skytide/tool_completion.dart';

import 'chat_attachment_check.dart' show check;

Future<void> main() async {
  const private = 'private marker';
  final preview = ChatReplyStream(publicOnly: true);
  final shown = [
    preview.add('我先核对第一份。'),
    preview.add('<think'),
    preview.add('ing>$private</thinking>'),
    preview.add('\n## 推'),
    preview.add('理过程：$private'),
    preview.finish(),
  ].join();
  check(shown == '我先核对第一份。', 'never preview split reasoning');
  check(visibleToolProgress('思考过程：$private').isEmpty, 'reasoning only');
  check(visibleToolProgress('[tool_call read_chat_file]').isEmpty, 'tool only');
  check(
    visibleToolProgress('<think>$private</think>我已经读完。') == '我已经读完。',
    'keep public text after tagged reasoning',
  );

  final calls = [
    {
      'index': 0,
      'id': 'call_file',
      'function': {'name': 'read_chat_file', 'arguments': '{"file_number":2}'},
    },
  ];
  for (final sse in [true, false]) {
    final message = {
      'content': '第一份已读，我再核对第二份。<inner_thought>$private</inner_thought>',
      'reasoning_content': private,
      'tool_calls': calls,
    };
    final payload = jsonEncode({
      'choices': [
        {sse ? 'delta' : 'message': message},
      ],
    });
    final (decoded, streamed) = await readToolCompletion(
      Stream.value(
        utf8.encode(sse ? 'data: $payload\n\ndata: [DONE]\n\n' : payload),
      ),
    );
    final assistant = decoded['choices'][0]['message'] as Map;
    check(
      streamed == sse && assistant['tool_calls'].length == 1,
      'tool transcript',
    );
    check(
      assistant['reasoning_content'] == private,
      'keep protocol reasoning internal',
    );
    check(
      visibleToolProgress(diaryResponseContent(assistant)) == '第一份已读，我再核对第二份。',
      'only public progress for either response mode',
    );
  }
  print('Tool progress checks passed.');
}
