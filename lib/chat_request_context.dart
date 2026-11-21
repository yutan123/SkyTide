/// Maintains a stable history start until the full budget is reached.
/// The caller persists [startId]; loading full database history must not restore
/// messages discarded by a previous rollover.
({int removed, int rolled, int tokens, String? startId}) rollStableHistory(
  List<Map<String, dynamic>> messages, {
  required int budget,
  required int Function(String) countTokens,
  String? startId,
}) {
  var removed = 0;
  if (startId != null && startId.isNotEmpty) {
    final index = messages.indexWhere((m) => m['id'] == startId);
    if (index > 0) {
      messages.removeRange(0, index);
      removed += index;
    }
  }
  final sizes = messages
      .map((m) => countTokens(m['content']?.toString() ?? ''))
      .toList();
  var tokens = sizes.fold<int>(0, (sum, size) => sum + size);
  var roll = 0;
  if (tokens >= budget) {
    while (tokens > budget ~/ 2 && roll < sizes.length - 1) {
      tokens -= sizes[roll++];
    }
  }
  if (roll > 0) messages.removeRange(0, roll);
  return (
    removed: removed + roll,
    rolled: roll,
    tokens: tokens,
    startId: messages.isEmpty ? null : messages.first['id']?.toString(),
  );
}

/// Adds deterministic speaker metadata without changing API roles or stored text.
/// In multimodal messages the marker is a text part; media payloads stay intact.
Map<String, dynamic> messageWithSpeaker(Map<String, dynamic> message) {
  final role = message['role'];
  if (role != 'user' && role != 'assistant') return Map.of(message);
  final marker = role == 'user' ? '[说话人:对方]' : '[说话人:你]';
  final content = message['content'];
  return {
    ...message,
    if (content is String) 'content': '$marker\n$content',
    if (content is List)
      'content': [
        {'type': 'text', 'text': marker},
        ...content,
      ],
  };
}

String messageTimeContext(String content, Object? timestamp) {
  final stamp = timestamp is num
      ? timestamp.toInt()
      : int.tryParse('$timestamp');
  if (stamp == null) return '[发送时间:未知]\n$content';
  final time = DateTime.fromMillisecondsSinceEpoch(stamp);
  String two(int value) => value.toString().padLeft(2, '0');
  return '[发送时间:${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}]\n$content';
}

String stickerModelContext({required String role, required String type}) {
  final actor = role == 'assistant' ? '你' : '对方';
  final label = type.trim().isEmpty ? '未分类' : type.trim();
  return '[$actor发送了一个表情包，表情包类型：$label]';
}

int? cachedPromptTokens(Map usage) {
  final details = usage['prompt_tokens_details'];
  final value =
      (details is Map ? details['cached_tokens'] : null) ??
      usage['cached_tokens'] ??
      usage['prompt_cache_hit_tokens'] ??
      usage['cache_read_input_tokens'];
  return value is num ? value.toInt() : null;
}

/// Marks up to four OpenAI cache boundaries: the fixed instructions and the
/// latest reusable user turns, before any per-request context.
List<int> gptChatCacheBreakpoints(
  List<Map<String, dynamic>> messages, {
  required int stableHistoryEnd,
}) {
  bool canMark(int index) {
    final content = messages[index]['content'];
    return content is String && content.trim().isNotEmpty;
  }

  if (messages.isEmpty) return const [];
  final history = <int>[];
  for (var i = stableHistoryEnd - 1; i > 0 && history.length < 3; i--) {
    final role = messages[i]['role'];
    final endsTurn =
        i == stableHistoryEnd - 1 || messages[i + 1]['role'] == 'user';
    if (endsTurn && (role == 'user' || role == 'assistant') && canMark(i)) {
      history.add(i);
    }
  }
  return [
    if (messages.first['role'] == 'system' && canMark(0)) 0,
    ...history.reversed,
  ];
}

/// Prepares Chat Completions messages without Anthropic-specific controls.
List<Map<String, dynamic>> prepareOpenAIChatCompletionMessages(
  List<Map<String, dynamic>> messages, {
  bool markFixedPrefix = false,
  List<int> breakpoints = const [],
}) {
  final indices = {
    ...breakpoints,
    if (markFixedPrefix &&
        messages.isNotEmpty &&
        messages.first['role'] == 'system')
      0,
  };
  return [
    for (var i = 0; i < messages.length; i++)
      Map<String, dynamic>.from(messages[i])
        ..remove('cache_control')
        ..updateAll((key, content) {
          final role = messages[i]['role'];
          if (key != 'content' ||
              !indices.contains(i) ||
              (role != 'system' && role != 'user' && role != 'assistant') ||
              content is! String ||
              content.trim().isEmpty) {
            return content;
          }
          return [
            {
              'type': 'text',
              'text': content,
              'prompt_cache_breakpoint': {'mode': 'explicit'},
            },
          ];
        }),
  ];
}

bool supportsGptChatCacheBreakpoint(String model) => RegExp(
  r'^gpt-(?:5\.(?:[6-9]|[1-9][0-9]+)|(?:[6-9]|[1-9][0-9]+)(?:\.[0-9]+)?)(?:-[a-z0-9]+)*$',
).hasMatch(model.trim().toLowerCase());

bool rejectsGptChatCacheBreakpoint(String body) {
  final error = body.toLowerCase();
  return error.contains('prompt_cache_breakpoint') ||
      error.contains('prompt_cache_options') ||
      (error.contains('messages') &&
          error.contains('content') &&
          error.contains('string') &&
          (error.contains('array') || error.contains('list')));
}

String memoryRecordedTime(Map<String, dynamic> memory) {
  final stamp = memory['timestamp'] ?? memory['created_at'];
  if (stamp is! num) return '未知';
  return DateTime.fromMillisecondsSinceEpoch(stamp.toInt()).toIso8601String();
}

List<String> recentMessageThoughts(List<Map<String, dynamic>> history) {
  final start = history.length > 3 ? history.length - 3 : 0;
  return history
      .skip(start)
      .where((m) => m['role'] == 'assistant')
      .map((m) => m['inner_thought']?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
}
