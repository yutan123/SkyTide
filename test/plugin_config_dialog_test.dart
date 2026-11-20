import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skytide/plugin_config_dialog.dart';
import 'package:skytide/ui_components.dart';

const _testLabel = '测试主邮箱 IMAP 连接';
const _schema = {
  'type': 'object',
  'x-ui': {'testLabel': _testLabel},
  'properties': {
    'name': {
      'type': 'string',
      'title': '邮箱备注名',
      'x-ui': {'group': '邮箱账户'},
    },
  },
};

void main() {
  testWidgets('reopening a group keeps editor state and dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PluginConfigDialog(title: '邮箱通知 设置', schema: _schema, values: {}),
      ),
    );

    final group = find.text('邮箱账户');
    final field = find.byType(TextField);
    await tester.enterText(field, 'Mailbox');
    await tester.pumpAndSettle();
    final originalSize = tester.getSize(field);
    final originalEditor = tester.state(find.byType(EditableText));

    for (var i = 0; i < 3; i++) {
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(originalEditor.mounted, isTrue);
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(tester.getSize(field), originalSize);
      expect(tester.state(find.byType(EditableText)), same(originalEditor));
      expect(tester.widget<TextField>(field).controller!.text, 'Mailbox');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('long actions fit within a narrow dialog at large text sizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: PluginConfigDialog(
          title: '邮箱通知 设置',
          schema: _schema,
          values: const {},
          onTest: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = tester.getRect(
      find
          .descendant(
            of: find.byType(TideDialogSurface),
            matching: find.byType(Container),
          )
          .first,
    );
    final testButton = tester.getRect(
      find.widgetWithText(TextButton, _testLabel),
    );
    final cancel = tester.getRect(find.widgetWithText(TextButton, '取消'));
    final save = tester.getRect(find.widgetWithText(FilledButton, '保存'));
    for (final button in [testButton, cancel, save]) {
      expect(button.left, greaterThan(surface.left));
      expect(button.right, lessThan(surface.right));
      expect(button.bottom, lessThan(surface.bottom));
    }
    expect(testButton.bottom, lessThanOrEqualTo(cancel.top));
    expect(save.center.dy, cancel.center.dy);
    expect(tester.takeException(), isNull);
  });
}
