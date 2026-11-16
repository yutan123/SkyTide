from pathlib import Path
r=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
p=r/'lib/ui_chat_room.dart';s=p.read_text().replace("import 'telegram_attachment_sheet.dart';", "import 'telegram_message_metadata.dart';\nimport 'telegram_attachment_sheet.dart';")
a=s.index('          if (theme.isTelegram)\n            Positioned(',s.index('  Widget build(BuildContext context)',s.index('class _ChatRoomPageState')))
b=s.index('          if (theme.isQq || theme.isTelegram) ...[',a)
shade=s[a:b]
s=s[:a]+s[b:]
needle='''          if (theme.isQq || theme.isTelegram) ...[
            Positioned.fill(child: _chatBody()),'''
assert needle in s
s=s.replace(needle,needle+'\n'+shade,1)
p.write_text(s)
p=r/'lib/ui_chat_room_telegram.dart';s=p.read_text()
a=s.index('  bool _telegramStartsDay(');b=s.index('  String _telegramDayLabel',a)
s=s[:a]+'''  bool _telegramStartsDay(int index) => telegramStartsNewDay(
    (_msgs[index]['timestamp'] as num?)?.toInt() ?? 0,
    index == 0 ? null : (_msgs[index - 1]['timestamp'] as num?)?.toInt() ?? 0,
  );

'''+s[b:]
a=s.index('  String _telegramTime(');b=s.index('Widget _telegramMessageStamp',a)
s=s[:a]+s[b:]
a=s.index('    final sending =',s.index('Widget _telegramMessageStamp'));b=s.index('    return Padding',a)
s=s[:a]+'''    final delivery = telegramDeliveryState(message);
    final sending = delivery == TelegramDeliveryState.sending;
    final failed = delivery == TelegramDeliveryState.failed;
'''+s[b:]
s=s.replace('_telegramTime(', 'telegramMessageTime(')
p.write_text(s)