from pathlib import Path
r=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
p=r/'lib/ui_chat_room.dart';s=p.read_text()
start=s.index('      itemBuilder: (ctx, i) {',s.index('  Widget _chatBody()'))
end=s.index('\n  List<Map<String, String>> _decodeSources',start)
old=s[start:end]
assert old.endswith('      },\n    );\n  }\n')
body=old[len('      itemBuilder: (ctx, i) {\n'):-len('      },\n    );\n  }\n')]
replacement='''      itemBuilder: (ctx, i) {
        final child = _chatMessage(ctx, i);
        if (!TideTheme.of(context).isTelegram) return child;
        return _telegramMessageRow(_msgs.length - 1 - i, child);
      },
    );
  }

  Widget _chatMessage(BuildContext ctx, int i) {
'''+body+'''  }
'''
s=s[:start]+replacement+s[end:]
s=s.replace("key: _messageKeys.putIfAbsent(\n            m['id']?.toString() ?? 'local_$i',\n            GlobalKey.new,\n          ),", "key: theme.isTelegram ? null : _messageKeys.putIfAbsent(\n            m['id']?.toString() ?? 'local_$i', GlobalKey.new),")
s=s.replace('if (theme.isTelegram ? _telegramStartsDay(messageIndex) : (theme.usesMessagingLayout &&', 'if (!theme.isTelegram && (theme.usesMessagingLayout &&')
s=s.replace('if ((isUser &&\n', 'if (!theme.isTelegram && ((isUser &&\n',1)
s=s.replace('(!isUser && showTimeForAssistant))', '(!isUser && showTimeForAssistant)))',1)
# Telegram does not show avatars beside each bubble, matching its private-chat layout.
s=s.replace('if (theme.usesMessagingLayout &&\n                                 _showChatAvatar', 'if (theme.usesMessagingLayout && !theme.isTelegram &&\n                                 _showChatAvatar')
s=s.replace('if (theme.usesMessagingLayout &&\n                                _showChatAvatar', 'if (theme.usesMessagingLayout && !theme.isTelegram &&\n                                _showChatAvatar')
p.write_text(s)
p=r/'lib/ui_chat_room_telegram.dart';s=p.read_text();a=s.index('  Widget _telegramHeader()');b=s.index('  Future<void> _telegramChatMenu',a)
s=s[:a]+'''  Widget _telegramHeader() {
    final theme = TideTheme.of(context);
    Widget button(IconData icon, String label, VoidCallback action) => TelegramGlass(child: SizedBox(width: 48, height: 48, child: IconButton(tooltip: label, onPressed: action, icon: Icon(icon, color: theme.textStrong))));
    return TweenAnimationBuilder<double>(key: ValueKey(_telegramMenuBounce), tween: Tween(begin: _telegramMenuBounce == 0 ? 1.0 : .96, end: 1), duration: const Duration(milliseconds: 480), curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, alignment: Alignment.topCenter, child: child),
      child: SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.fromLTRB(7, 5, 7, 12), child: Row(children: [
        button(Icons.arrow_back_rounded, '返回', () => Navigator.pop(context)),
        const SizedBox(width: 7),
        Expanded(child: TelegramGlass(child: SizedBox(height: 48, child: Stack(alignment: Alignment.center, children: [
          Positioned(left: 3, child: TideBotAvatar(name: _bot['name']?.toString() ?? '', path: _bot['avatar']?.toString(), size: 42, radius: 21)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 48), child: Stack(alignment: Alignment.center, children: [
            AnimatedAlign(duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic, alignment: _typing ? const Alignment(0, -.55) : Alignment.center, child: Text(_bot['name']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: theme.textStrong))),
            Align(alignment: const Alignment(0, .72), child: AnimatedOpacity(duration: const Duration(milliseconds: 180), opacity: _typing ? 1 : 0, child: Text('正在输入中…', style: TextStyle(fontSize: 10, color: theme.primary)))),
          ])),
        ])))),
        const SizedBox(width: 7),
        Builder(builder: (anchor) => button(Icons.more_vert, '聊天菜单', () => _telegramChatMenu(anchor))),
      ])))));
  }

  bool _telegramStartsDay(int index) {
    if (index == 0) return true;
    final current = DateTime.fromMillisecondsSinceEpoch((_msgs[index]['timestamp'] as num?)?.toInt() ?? 0);
    final previous = DateTime.fromMillisecondsSinceEpoch((_msgs[index - 1]['timestamp'] as num?)?.toInt() ?? 0);
    return current.year != previous.year || current.month != previous.month || current.day != previous.day;
  }

  String _telegramDayLabel(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    return '${date.year == now.year ? '' : '${date.year}年'}${date.month}月${date.day}日';
  }

  Widget _telegramMessageRow(int index, Widget child) {
    final message = _msgs[index];
    final theme = TideTheme.of(context);
    final streaming = message['id'].toString().startsWith('stream_');
    return GestureDetector(key: _messageKeys.putIfAbsent(message['id']?.toString() ?? 'telegram_$index', GlobalKey.new), onLongPress: () => _telegramMessageMenu(message), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_telegramStartsDay(index)) Center(child: Container(margin: const EdgeInsets.only(top: 12, bottom: 14), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), decoration: BoxDecoration(color: theme.isDark ? Colors.black26 : const Color(0x66587850), borderRadius: BorderRadius.circular(20)), child: Text(_telegramDayLabel((message['timestamp'] as num?)?.toInt() ?? 0), style: const TextStyle(color: Colors.white, fontSize: 12)))),
      child,
      if (!streaming) Align(alignment: message['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(bottom: 7, left: 8, right: 8), child: _telegramMessageStamp(message))),
    ]));
  }

'''+s[b:]
s=s.replace("else if (result.kind != null) { await _pickMediaSource(result.kind!); }", "else { await _pickMediaSource(result.kind); }")
s=s.replace("final sending = message['send_status'] == 'sending' || message['is_retrying'] == true;", "final sending = message['send_status'] == 'sending' || message['is_retrying'] == true || message['retry_status'] == 'retrying';")
s=s.replace("if (_showMessageTime) Text(fmtTime((message['timestamp'] as num?)?.toInt() ?? 0),", "Text(_telegramTime((message['timestamp'] as num?)?.toInt() ?? 0),")
s=s.replace('  Widget _telegramMessageStamp', "  String _telegramTime(int timestamp) {\n    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);\n    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';\n  }\n\n  Widget _telegramMessageStamp")
p.write_text(s)
