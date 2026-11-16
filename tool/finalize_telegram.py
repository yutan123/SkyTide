from pathlib import Path
r=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
p=r/'lib/ui_chat_room_telegram.dart';s=p.read_text()
s=s.replace('onTap: () => _selectEmoji(emoji),', 'onTap: () => _insertWechatEmoji(emoji),')
s=s.replace('''onTap: () => _updateTelegram(
                            () => _pendingExpression =
                                _PendingExpression.sticker(sticker),
                          ),''', '''onTap: () => _selectSticker(sticker),''')
a=s.index("                    onPressed: () {",s.index("tooltip: '删除',"));b=s.index("                    icon: Icon(Icons.backspace",a)
s=s[:a]+'''                    onPressed: _deleteWechatEmoji,
'''+s[b:]
s=s.replace('''      await DBManager().deleteMessage(msg['id'].toString());
      if (mounted)
        _updateTelegram(() {
          _messagesRevision++;
          _msgs.removeWhere((m) => m['id'] == msg['id']);
        });''','''      try {
        await DBManager().deleteMessage(msg['id'].toString());
        if (mounted) _updateTelegram(() {
          _messagesRevision++;
          _msgs.removeWhere((m) => m['id'] == msg['id']);
          _messageKeys.remove(msg['id']?.toString());
        });
      } catch (_) {
        if (mounted) GlobalNotice.show('删除失败，请重试');
      }''')
s=s.replace('''child: _emojiTab == 1
                  ? GridView.builder(''','''child: _emojiTab == 1
                  ? !_stickersLoaded
                    ? Center(child: CircularProgressIndicator(color: theme.primary))
                    : _stickers.isEmpty
                      ? Center(child: Text('暂无我的表情', style: TextStyle(color: theme.textWeak)))
                      : GridView.builder(''')
p.write_text(s)
p=r/'lib/telegram_attachment_sheet.dart';s=p.read_text().replace("WidgetsBinding.instance.addPostFrameCallback((_) => _load());", "WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); });").replace('if (_loading || !_hasMore) return;', 'if (!mounted || _loading || !_hasMore) return;');p.write_text(s)
p=r/'android/app/src/main/kotlin/com/yutan123/tidebot/ChatGallery.kt';s=p.read_text().replace('    fun page(', '    @Suppress("DEPRECATION")\n    fun page(').replace('else @Suppress("DEPRECATION") MediaStore.Images.Thumbnails.getThumbnail(', 'else MediaStore.Images.Thumbnails.getThumbnail(');p.write_text(s)