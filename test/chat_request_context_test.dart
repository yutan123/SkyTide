import 'package:flutter_test/flutter_test.dart';
import 'package:skytide/chat_request_context.dart';

void main() {
  test(
    'persisted window survives full history reload across consecutive turns',
    () {
      final database = List.generate(
        10,
        (i) => <String, dynamic>{
          'id': '$i',
          'role': 'user',
          'content': 'a' * 10,
        },
      );
      final first = database.map((m) => Map<String, dynamic>.from(m)).toList();
      final rolled = rollStableHistory(
        first,
        budget: 100,
        countTokens: (s) => s.length,
      );
      expect(rolled.startId, '5');
      expect(rolled.tokens, 50);
      for (var turn = 10; turn < 14; turn++) {
        database.add({'id': '$turn', 'role': 'user', 'content': 'a' * 10});
        final reloaded = database
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        final next = rollStableHistory(
          reloaded,
          budget: 100,
          countTokens: (s) => s.length,
          startId: rolled.startId,
        );
        expect(next.startId, '5');
        expect(reloaded.take(first.length), first);
      }
    },
  );
  test(
    'rollover preserves oversized latest message and handles deleted cursor',
    () {
      final history = <Map<String, dynamic>>[
        {'id': 'a', 'content': 'x'},
        {'id': 'b', 'content': 'y' * 120},
      ];
      final result = rollStableHistory(
        history,
        budget: 100,
        countTokens: (s) => s.length,
        startId: 'deleted',
      );
      expect(result.startId, 'b');
      expect(result.tokens, 120);
      expect(history.length, 1);
      expect(
        rollStableHistory(
          [],
          budget: 100,
          countTokens: (s) => s.length,
        ).startId,
        isNull,
      );
    },
  );
  test('sticker descriptions identify both actors and always include type', () {
    expect(
      stickerModelContext(role: 'user', type: '开心'),
      '[对方发送了一个表情包，表情包类型：开心]',
    );
    expect(
      stickerModelContext(role: 'assistant', type: ' 害羞 '),
      '[你发送了一个表情包，表情包类型：害羞]',
    );
    expect(
      stickerModelContext(role: 'assistant', type: ''),
      '[你发送了一个表情包，表情包类型：未分类]',
    );
  });
  test(
    'cache usage supports provider formats and does not treat missing as zero',
    () {
      expect(
        cachedPromptTokens({
          'prompt_tokens_details': {'cached_tokens': 12000},
        }),
        12000,
      );
      expect(
        cachedPromptTokens({
          'prompt_tokens_details': {},
          'prompt_cache_hit_tokens': 2000,
        }),
        2000,
      );
      expect(cachedPromptTokens({'cache_read_input_tokens': 1000}), 1000);
      expect(cachedPromptTokens({'cached_tokens': 0}), 0);
      expect(cachedPromptTokens({}), isNull);
    },
  );
  test('OpenAI Chat Completions removes non-standard cache breakpoints', () {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': 'stable',
        'cache_control': {'type': 'ephemeral'},
      },
      {'role': 'user', 'content': 'hello'},
    ];

    final prepared = prepareOpenAIChatCompletionMessages(messages);

    expect(prepared.first, {'role': 'system', 'content': 'stable'});
    expect(messages.first.containsKey('cache_control'), isTrue);
    expect(prepared.last, {'role': 'user', 'content': 'hello'});
  });

  test('OpenAI breakpoints follow stable turns, not the dynamic tail', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'fixed'},
      for (var turn = 0; turn < 4; turn++) ...[
        {'role': 'user', 'content': 'question $turn'},
        {'role': 'assistant', 'content': 'answer $turn part 1'},
        {'role': 'assistant', 'content': 'answer $turn part 2'},
      ],
      {'role': 'system', 'content': 'dynamic'},
      {'role': 'user', 'content': 'current'},
    ];
    final previous = gptChatCacheBreakpoints(messages, stableHistoryEnd: 10);
    final current = gptChatCacheBreakpoints(messages, stableHistoryEnd: 13);
    expect(previous, [0, 3, 6, 9]);
    expect(current, [0, 6, 9, 12]);
    final prepared = prepareOpenAIChatCompletionMessages(
      messages,
      breakpoints: current,
    );
    expect(prepared[9]['content'], [
      {
        'type': 'text',
        'text': 'answer 2 part 2',
        'prompt_cache_breakpoint': {'mode': 'explicit'},
      },
    ]);
    expect(prepared.skip(13), messages.skip(13));
    expect(messages[9]['content'], 'answer 2 part 2');
  });
}
