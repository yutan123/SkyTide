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

/// Annotates current and historical messages with the same wire representation.
Map<String, dynamic> annotateChatMessage(
  Map<String, dynamic> message,
  Object? timestamp,
) {
  final content = message['content'];
  return messageWithSpeaker({
    ...message,
    if (content is String) 'content': messageTimeContext(content, timestamp),
    if (content is List)
      'content': [
        {'type': 'text', 'text': messageTimeContext('', timestamp)},
        ...content,
      ],
  });
}

/// Returns the timestamp of the last persisted user row in the current batch.
Object? savedUserBatchTimestamp(
  List<Map<String, dynamic>> chronologicalRows,
  Set<String> currentMessageIds,
) {
  if (currentMessageIds.isEmpty) return null;
  for (final row in chronologicalRows.reversed) {
    if (row['role'] == 'user' &&
        currentMessageIds.contains(row['id']?.toString())) {
      return row['timestamp'];
    }
  }
  return null;
}

/// Keeps the current user message in the same position when it joins history.
/// Turn-specific system messages retain their roles and order.
void moveUserBeforeTurnContext(
  List<Map<String, dynamic>> messages,
  int historyEnd,
) {
  if (historyEnd < messages.length - 1 && messages.last['role'] == 'user') {
    messages.insert(historyEnd, messages.removeLast());
  }
}

String stickerModelContext({required String role, required String type}) {
  final actor = role == 'assistant' ? '你' : '对方';
  final label = type.trim().isEmpty ? '未分类' : type.trim();
  return '[$actor发送了一个表情包，表情包类型：$label]';
}

int? cachedPromptTokens(Map usage) {
  final details = usage['prompt_tokens_details'];
  final inputDetails = usage['input_tokens_details'];
  final value =
      (inputDetails is Map ? inputDetails['cached_tokens'] : null) ??
      (details is Map ? details['cached_tokens'] : null) ??
      usage['cached_tokens'] ??
      usage['prompt_cache_hit_tokens'] ??
      usage['cache_read_input_tokens'];
  return value is num ? value.toInt() : null;
}

List<Map<String, dynamic>> prepareOpenAIChatCompletionMessages(
  List<Map<String, dynamic>> messages,
) => [for (final message in messages) Map.of(message)..remove('cache_control')];

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
