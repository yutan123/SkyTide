from pathlib import Path
r=Path('/data/data/com.ai.assistance.operit/files/workspace/TideBot-Dev')
for name in ['ui_profile.dart','ui_chat_list.dart']:
 p=r/'lib'/name;p.write_text(p.read_text().replace("import 'telegram_theme_widgets.dart';\n",''))
p=r/'lib/telegram_attachment_sheet.dart';s=p.read_text().replace("import 'dart:typed_data';\n",'');s=s.replace('height * .17 * Curves.easeInOut.transform(_motion.value)', '''height * .17 * (_motion.status == AnimationStatus.reverse
                ? 1 - Curves.easeOutBack.transform(1 - _motion.value)
                : Curves.easeInOut.transform(_motion.value))''');p.write_text(s)
p=r/'lib/ui_chat_room.dart';s=p.read_text().replace('''                child: qq
                    ? OverflowBox(''','''                child: (qq || TideTheme.of(context).isTelegram)
                    ? OverflowBox(''');p.write_text(s)
p=r/'lib/telegram_theme_widgets.dart';s=p.read_text().replace('Alignment.bottomCenter : Alignment.topRight','Alignment.center : Alignment.center');s=s.replace('''alignment: preferAbove
                      ? Alignment.bottomCenter
                      : Alignment.topRight,''','''alignment: Alignment.center,''');p.write_text(s)
