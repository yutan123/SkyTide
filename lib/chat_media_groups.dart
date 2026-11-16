/// A display row retains indexes into the original chronological history.
/// Grouping never changes persisted messages or the history sent to the model.
class ChatMediaRow {
  const ChatMediaRow(this.indexes, {this.groupId});

  final List<int> indexes;
  final String? groupId;
  int get firstIndex => indexes.first;
  bool get isGroup => groupId != null;
}

final _attachmentId = RegExp(r'^m_(\d+)_(\d+)$');

String? _batchKey(Map<String, dynamic> message) {
  // Composer attachments already persist m_<turn timestamp>_<attachment index>.
  // Use that identity rather than a time window, which could merge separate sends.
  if (message['role'] != 'user') return null;
  final match = _attachmentId.firstMatch(message['id']?.toString() ?? '');
  if (match == null) return null;
  return '${message['bot_id'] ?? ''}:${match.group(1)}';
}

List<ChatMediaRow> buildChatMediaRows(
  List<Map<String, dynamic>> messages, {
  required bool Function(Map<String, dynamic>) isMedia,
  Set<String> expandedGroups = const {},
}) {
  final rows = <ChatMediaRow>[];
  var index = 0;
  while (index < messages.length) {
    final batch = _batchKey(messages[index]);
    var end = index + 1;
    if (batch != null) {
      while (end < messages.length && _batchKey(messages[end]) == batch) {
        end++;
      }
    }
    final mediaIndexes = <int>[
      for (var item = index; item < end; item++)
        if (isMedia(messages[item])) item,
    ];
    // The batch identity stays stable when its first attachment is deleted.
    final groupId = batch == null ? null : 'media:$batch';
    final collapsed =
        batch != null &&
        mediaIndexes.length >= 3 &&
        !expandedGroups.contains(groupId);
    for (var item = index; item < end; item++) {
      if (collapsed && isMedia(messages[item])) {
        if (item == mediaIndexes.first) {
          rows.add(ChatMediaRow(mediaIndexes, groupId: groupId));
        }
      } else {
        rows.add(ChatMediaRow([item]));
      }
    }

    index = end;
  }
  return rows;
}
