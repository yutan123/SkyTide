import 'dart:isolate';

import 'package:tide_bot/chat_message_display.dart';

Future<void> main() async {
  final rows = List.generate(
    2000,
    (index) => Map<String, dynamic>.unmodifiable({
      'id': 'm_$index',
      'role': index.isEven ? 'user' : 'assistant',
      'type': 'text',
      'content': '消息 $index',
      'timestamp': index,
      if (index == 1999) 'inner_thought': '想法',
    }),
  );
  final input = editableChatHistory(rows);
  final normalized = await Isolate.run(() => normalizeChatMessages(input));
  if (normalized.length != 2001 ||
      normalized.first['id'] != 'm_0' ||
      normalized[1999]['id'] != 'm_1999_thought' ||
      normalized.last['id'] != 'm_1999') {
    throw StateError('Long history changed across the isolate boundary');
  }
  normalized.last['_thought_expanded'] = true;
  if (rows.last.containsKey('_thought_expanded')) {
    throw StateError('Display state leaked into the database snapshot');
  }
  final merged = normalizeChatMessages([
    ...normalized,
    {
      'id': 'local',
      'role': 'user',
      'type': 'text',
      'content': '新消息',
      'timestamp': 2000,
    },
  ]);
  if (merged.length != 2002 || merged.last['id'] != 'local') {
    throw StateError('Local message merge lost history or duplicated thoughts');
  }
  print('Long history isolate and local merge checks passed');
}
