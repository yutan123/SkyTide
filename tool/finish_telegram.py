from pathlib import Path
root=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
p=root/'lib/ui_chat_room.dart'
s=p.read_text()
def replace(a,b):
 global s
 assert a in s,a[:100]
 s=s.replace(a,b,1)
replace('class _EmojiAsset {',"part 'ui_chat_room_telegram.dart';\n\nclass _EmojiAsset {")
replace('  bool _typing = false;',"  int _telegramMenuBounce = 0;\n  String _telegramEmojiSearch = '';\n  bool _typing = false;")
replace('  Widget _emojiPicker(TideTheme theme) {','  Widget _emojiPicker(TideTheme theme) {\n    if (theme.isTelegram) return _telegramEmojiPicker(theme);')
replace('  void _msgLongPress(Map<String, dynamic> msg) {','  void _msgLongPress(Map<String, dynamic> msg) {\n    if (TideTheme.of(context).isTelegram) {\n      _telegramMessageMenu(msg);\n      return;\n    }')
replace(': const DefaultChatBackground(),\n          ),',': theme.isTelegram ? const TelegramWallpaper() : const DefaultChatBackground(),\n          ),')
replace('          if (theme.isQq) ...[','''          if (theme.isTelegram)
            Positioned(left: 0, right: 0, top: 0, height: MediaQuery.paddingOf(context).top + 100,
              child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: .18), Colors.transparent]))))),
          if (theme.isQq || theme.isTelegram) ...[''')
replace('    if (theme.isQq) return _qqHeader();','    if (theme.isTelegram) return _telegramHeader();\n    if (theme.isQq) return _qqHeader();')
replace("      ? QqBubble(isUser: isUser, child: child)","      ? QqBubble(isUser: isUser, child: child)") if False else None
replace('  Widget _messageVoiceBubble({required bool isUser, required Widget child}) =>\n', '  Widget _messageVoiceBubble({required bool isUser, required Widget child}) =>\n      TideTheme.of(context).isTelegram ? TelegramBubble(isUser: isUser, child: child) :\n')
replace('        TideTheme.of(context).isQq\n            ? MediaQuery.paddingOf(context).top + _qqHeaderHeight + 12','        (TideTheme.of(context).isQq || TideTheme.of(context).isTelegram)\n            ? MediaQuery.paddingOf(context).top + (TideTheme.of(context).isTelegram ? 74 : _qqHeaderHeight) + 12')
replace('''                         if (theme.usesMessagingLayout &&''','''                         if (theme.usesMessagingLayout &&''') if False else None
replace('''                        if (theme.usesMessagingLayout &&
                            _showMessageTime &&''','''                        if (theme.isTelegram ? _telegramStartsDay(messageIndex) : (theme.usesMessagingLayout &&
                            _showMessageTime &&''')
replace('''                                    300000))
''','''                                    300000)))
''')
replace('                                    fmtTime(ts),',"                                    theme.isTelegram ? _telegramDayLabel(ts) : fmtTime(ts),")
replace('''                                   if (showTideAvatar)''','''                                   if (showTideAvatar)''') if False else None
# Time follows the media/text content in the shared message column.
needle='''                                  if (showTideAvatar)
                                    _tideMessageAvatar(isUser),'''
# insert stamp after all existing content by using final source block boundary below
replace('''    if (theme.isQq) {
      return QqBubble(''','''    if (theme.isTelegram) {
      return TelegramBubble(isUser: isUser, child: RichText(textScaler: MediaQuery.textScalerOf(context), text: TextSpan(style: baseStyle, children: spans)));
    }
    if (theme.isQq) {
      return QqBubble(''')
replace('''      color: theme.isWechat
''','''      color: theme.isTelegram ? theme.textStrong : theme.isWechat
''')
replace('''    if (theme.isQq) return _qqInputBar();''','''    if (theme.isTelegram) return _telegramInputBar();
    if (theme.isQq) return _qqInputBar();''')
p.write_text(s)
