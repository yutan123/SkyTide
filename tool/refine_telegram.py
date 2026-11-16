from pathlib import Path
r=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
p=r/'lib/telegram_theme_widgets.dart';s=p.read_text()
s=s.replace('this.radius = 28});','this.radius = 28, this.fillOpacity});')
# constructor has multiline formatting
s=s.replace('''    this.radius = 28,
  });''','''    this.radius = 28,
    this.fillOpacity,
  });''')
s=s.replace('  final double radius;','  final double radius;\n  final double? fillOpacity;',1)
s=s.replace('alpha: theme.isDark ? .78 : .83', 'alpha: fillOpacity ?? (theme.isDark ? .78 : .83)')
s=s.replace('''}) {
  final navigator''','''}) async {
  final navigator''',1)
s=s.replace('''  return showGeneralDialog<T>(
    context: context,''','''  final route = RawDialogRoute<T>(''',1)
s=s.replace('''        radius: 26,
        child: Material(''','''        radius: 26,
        fillOpacity: TideTheme.of(context).isDark ? .72 : .64,
        child: Material(''',1)
s=s.replace('''              alignment: preferAbove
                  ? Alignment.bottomCenter
                  : Alignment.topRight,''','''              alignment: Alignment.center,''')
s=s.replace('''  );
}

class TelegramMenuItem''','''  );
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}

class TelegramMenuItem''',1)
p.write_text(s)
p=r/'lib/ui_chat_room_telegram.dart';s=p.read_text();s=s.replace('_sendVoiceCooldown.isBlocked\n', '(!_isRecording && _sendVoiceCooldown.isBlocked)\n')
p.write_text(s)
p=r/'lib/ui_chat_list.dart';s=p.read_text().replace("? '点击右上角 + 创建'\n                                  : '点击右下角 + 创建'", "? '点击右上角 + 创建'\n                                  : theme.isTelegram ? '点击右下角按钮创建机器人' : '点击右下角 + 创建'");p.write_text(s)