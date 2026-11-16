from pathlib import Path
r=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
def edit(name, old, new):
 p=r/name;s=p.read_text();assert old in s,(name,old[:70]);p.write_text(s.replace(old,new,1))
edit('lib/theme.dart',"bool get usesMessagingLayout => isWechat || isQq;", "bool get isTelegram => _interfaceTheme == 'telegram';\n  bool get usesMessagingLayout => isWechat || isQq || isTelegram;")
edit('lib/theme.dart',"{'default', 'wechat', 'qq'}", "{'default', 'wechat', 'qq', 'telegram'}")
edit('lib/theme.dart',"{'wechat', 'qq'}.contains(style)","{'wechat', 'qq', 'telegram'}.contains(style)")
edit('lib/theme.dart','Color get primary => isQq',"Color get primary => isTelegram ? const Color(0xFF12B86A) : isQq")
edit('lib/theme.dart','Color get primaryLight => isQq',"Color get primaryLight => isTelegram ? const Color(0xFF71D4A4) : isQq")
edit('lib/theme.dart','Color get pageBackground => isQq',"Color get pageBackground => isTelegram ? (isDark ? const Color(0xFF17212B) : const Color(0xFFF1F1F3)) : isQq")
for name in ['lib/main.dart','lib/ui_chat_list.dart','lib/ui_profile.dart','lib/ui_chat_room.dart']:
 p=r/name;s=p.read_text();s="import 'telegram_theme_widgets.dart';\n"+s;p.write_text(s)
edit('lib/interface_theme_page.dart',"          InterfaceThemeCard(\n            title: 'QQ风格主题',", "          InterfaceThemeCard(\n            title: 'Telegram风格主题',\n            applied: theme.isTelegram,\n            busy: _saving,\n            onPressed: () => _select(theme.isTelegram ? 'default' : 'telegram'),\n          ),\n          const SizedBox(height: 20),\n          InterfaceThemeCard(\n            title: 'QQ风格主题',")
edit('lib/main.dart','          if (theme.isQq)\n            Positioned(','''          if (theme.isTelegram)
            Positioned(left: 16, right: 16, bottom: bottomPadding + 8,
              child: TelegramNavigationBar(index: _idx, unread: _unreadCount, onTap: _onDockTap)),
          if (theme.isQq)
            Positioned(''')
edit('lib/main.dart','if (_idx == 0 && !theme.usesMessagingLayout)', 'if (_idx == 0 && (!theme.usesMessagingLayout || theme.isTelegram))')
edit('lib/main.dart','bottom: bottomPadding + 76,','bottom: bottomPadding + (theme.isTelegram ? 92 : 76),')
edit('lib/main.dart','                  width: 48,\n                  height: 48,','                  width: theme.isTelegram ? 56 : 48,\n                  height: theme.isTelegram ? 56 : 48,')
edit('lib/main.dart','                    gradient: LinearGradient(\n                      colors: [theme.primary, theme.primaryLight],\n                    ),','                    color: theme.isTelegram ? telegramGreen : null,\n                    gradient: theme.isTelegram ? null : LinearGradient(\n                      colors: [theme.primary, theme.primaryLight],\n                    ),')
edit('lib/main.dart', '                  child: const Icon(\n                    Icons.add_rounded,', '                  child: Icon(\n                    theme.isTelegram ? Icons.edit_rounded : Icons.add_rounded,')
edit('lib/ui_chat_list.dart','              if (theme.isQq)', '''              if (theme.isTelegram)
                Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 16), child: Align(alignment: Alignment.centerLeft, child: GestureDetector(onTap: _openSidebar, child: Text('TideBot', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700, color: theme.primary)))))
              else if (theme.isQq)''')
edit('lib/ui_chat_list.dart','theme.usesMessagingLayout\n                                  ?','theme.usesMessagingLayout && !theme.isTelegram\n                                  ?')
edit('lib/ui_chat_list.dart','bottom: TideTheme.of(context).isQq','bottom: (TideTheme.of(context).isQq || TideTheme.of(context).isTelegram)')
# Telegram rows have large round avatars and flat list surfaces.
p=r/'lib/ui_chat_list.dart';s=p.read_text();a=s.index('  Widget _wechatRow');b=s.index('  Widget _card',a);chunk=s[a:b].replace('theme.isQq','(theme.isQq || theme.isTelegram)').replace('? 26 : 5','? (theme.isTelegram ? 28 : 26) : 5').replace('? 52 : 42','? (theme.isTelegram ? 56 : 52) : 42');s=s[:a]+chunk+s[b:];p.write_text(s)
# Settings retain all existing routes, grouped as one rounded panel.
edit('lib/ui_profile.dart','            ..._settings.map(','''            if (TideTheme.of(context).isTelegram)
              Container(decoration: BoxDecoration(color: TideTheme.of(context).surface, borderRadius: BorderRadius.circular(24)), clipBehavior: Clip.antiAlias,
                child: Column(children: [for (final s in _settings) InkWell(onTap: () => _onSetting(s), child: _buildSettingItem(s))]))
            else ..._settings.map(''')
edit('lib/ui_profile.dart','    if (theme.isQq) {','    if (theme.isQq || theme.isTelegram) {')
edit('lib/ui_profile.dart','    final content = Row(\n      children: [\n        Icon(s[\'icon\'] as IconData, size: 24, color: theme.primary),', '''    if (theme.isTelegram) {
      final colors = [Colors.blue, Colors.orange, Colors.green, Colors.purple, Colors.red, Colors.teal];
      final color = colors[_settings.indexOf(s).clamp(0, _settings.length) % colors.length];
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15), child: Row(children: [
        Container(width: 32, height: 32, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)), child: Icon(s['icon'] as IconData, color: Colors.white, size: 22)),
        const SizedBox(width: 16), Expanded(child: Text(s['title'] ?? '', style: TextStyle(fontSize: 17, color: theme.textStrong))),
      ]));
    }
    final content = Row(
      children: [
        Icon(s['icon'] as IconData, size: 24, color: theme.primary),''')
