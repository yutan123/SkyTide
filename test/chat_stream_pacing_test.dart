import 'package:flutter_test/flutter_test.dart';
import 'package:skytide/chat_stream_pacing.dart';

void main() {
  test('live buffer starts on character 21 and drains during a pause', () {
    final buffer = ChatStreamBuffer()..add('甲' * 20);
    expect(buffer.tick(), isFalse);
    buffer.add('乙');
    expect(buffer.tick(), isTrue);
    expect(buffer.visible, '甲');
    for (var i = 0; i < 20; i++) {
      expect(buffer.tick(), isTrue);
    }
    expect(buffer.tick(), isFalse);
    buffer.add('丙丁');
    expect(buffer.tick(), isTrue);
    expect(buffer.visible, '甲' * 20 + '乙丙');
  });

  test('final reveal continues from the visible prefix', () async {
    expect(await chatStreamText('甲乙丙', 100, prefix: '甲').toList(), [
      '甲乙',
      '甲乙丙',
    ]);
  });
  test('chat speed remains readable throughout the settings range', () {
    expect(chatStreamInterval(1).inMilliseconds, 270);
    expect(chatStreamInterval(50).inMilliseconds, 170);
    expect(chatStreamInterval(100).inMilliseconds, 68);
  });

  test(
    'large provider chunks are consumed one visible character at a time',
    () {
      var pending = '你好👨‍👩‍👧‍👦e\u0301！';
      final displayed = <String>[];
      while (pending.isNotEmpty) {
        final (character, remainder) = takeChatStreamCharacter(pending);
        displayed.add(character);
        pending = remainder;
      }
      expect(displayed, ['你', '好', '👨‍👩‍👧‍👦', 'e\u0301', '！']);
      expect(takeChatStreamCharacter(''), ('', ''));
    },
  );

  test('completed provider text still follows the client pace', () async {
    final watch = Stopwatch()..start();
    final visible = <String>[];
    await for (final text in chatStreamText('你👨‍👩‍👧‍👦好', 100)) {
      expect(
        watch.elapsedMilliseconds,
        greaterThanOrEqualTo(chatStreamInterval(100).inMilliseconds),
      );
      visible.add(text);
      watch.reset();
    }
    expect(visible, ['你', '你👨‍👩‍👧‍👦', '你👨‍👩‍👧‍👦好']);
  });

  test('segments drain in order without flushing the next segment', () async {
    final visible = <String>[];
    for (final segment in ['甲。', '乙！']) {
      await for (final text in chatStreamText(segment, 100)) {
        visible.add(text);
      }
    }
    expect(visible, ['甲', '甲。', '乙', '乙！']);
  });
}
