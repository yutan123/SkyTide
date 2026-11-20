import 'dart:convert';
import 'package:skytide/chat_media_groups.dart';

int _checks = 0;
void check(bool value, String message) {
  if (!value) throw StateError(message);
  _checks++;
}

Map<String, dynamic> media(int batch, int index, [String type = 'image']) => {
  'id': 'm_${batch}_$index',
  'bot_id': 'bot',
  'role': 'user',
  'type': type,
  'file_path': '/media/$batch-$index.${type == 'video' ? 'mp4' : 'jpg'}',
  'content': index == 0 ? '旅行照片' : '',
  'timestamp': batch + index,
};

bool isMedia(Map<String, dynamic> message) =>
    {'image', 'video'}.contains(message['type']);
List<ChatMediaRow> rows(
  List<Map<String, dynamic>> messages, {
  Set<String> expanded = const {},
}) => buildChatMediaRows(messages, isMedia: isMedia, expandedGroups: expanded);

void main() {
  check(rows([]).isEmpty, 'Empty history remains empty');
  check(rows([media(100, 0)]).length == 1, 'One photo stays individual');
  final pair = rows([media(100, 0), media(100, 1)]);
  check(
    pair.length == 2 && pair.every((row) => !row.isGroup),
    'Two photos do not collapse',
  );

  final batch = [for (var i = 0; i < 14; i++) media(100, i)];
  final before = jsonEncode(batch);
  final collapsed = rows(batch);
  check(
    collapsed.length == 1 && collapsed.single.isGroup,
    'Fourteen photos form one deck',
  );
  check(
    collapsed.single.indexes.join(',') == List.generate(14, (i) => i).join(','),
    'Every card retains its original order',
  );
  check(
    jsonEncode(batch) == before,
    'Grouping never mutates history or captions',
  );

  final mixed = [media(200, 0), media(200, 1, 'video'), media(200, 2)];
  check(rows(mixed).single.isGroup, 'Three mixed images/videos collapse');
  check(
    rows([for (var i = 0; i < 3; i++) media(300, i, 'video')]).single.isGroup,
    'Video-only batches collapse',
  );
  final groupId = collapsed.single.groupId!;
  final expanded = rows(batch, expanded: {groupId});
  check(
    expanded.length == 14 && expanded.every((row) => !row.isGroup),
    'Expand reveals every original message',
  );
  check(
    expanded.map((row) => row.firstIndex).join(',') ==
        List.generate(14, (i) => i).join(','),
    'Expanded order is unchanged',
  );
  check(
    rows(batch).single.isGroup,
    'A new visit with no expansion state is collapsed again',
  );
  final restored = (jsonDecode(before) as List)
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList();
  check(
    rows(restored).single.groupId == groupId,
    'Persisted IDs restore the same group without new database fields',
  );

  final separateSends = [media(400, 0), media(401, 0), media(402, 0)];
  check(
    rows(separateSends).length == 3,
    'Nearby timestamps cannot merge separate sends',
  );
  final twoBatches = [...mixed, ...batch];
  check(
    rows(twoBatches).length == 2 &&
        rows(twoBatches).every((row) => row.isGroup),
    'Adjacent batches remain separate decks',
  );
  final otherRole = [
    for (var i = 0; i < 3; i++) {...media(500, i), 'role': 'assistant'},
  ];
  check(
    rows(otherRole).length == 3,
    'Assistant IDs cannot be mistaken for a send',
  );
  final differentBots = [
    media(600, 0),
    {...media(600, 1), 'bot_id': 'other'},
    media(600, 2),
  ];
  check(rows(differentBots).length == 3, 'Different chats never merge');
  final withDocument = [
    media(700, 0),
    media(700, 1, 'document'),
    media(700, 2, 'video'),
    media(700, 3),
  ];
  final documentRows = rows(withDocument);
  check(
    documentRows.length == 2 &&
        documentRows.first.indexes.join(',') == '0,2,3' &&
        documentRows.last.firstIndex == 1,
    'Ordinary documents remain visible beside the media group',
  );
  check(
    rows(
          withDocument,
          expanded: {documentRows.first.groupId!},
        ).map((row) => row.firstIndex).join(',') ==
        '0,1,2,3',
    'Expanding mixed attachments restores the original full order',
  );
  check(
    rows([media(800, 0), media(800, 2)]).length == 2,
    'Deleting below the threshold restores individual cards',
  );
  final remainingBatch = batch.skip(1).toList();
  check(
    rows(remainingBatch).single.groupId == groupId,
    'Deleting the first attachment preserves the batch identity',
  );
  check(
    rows(remainingBatch, expanded: {groupId}).every((row) => !row.isGroup),
    'Deleting the first attachment cannot collapse an expanded batch',
  );
  final unknownIds = [
    for (var i = 0; i < 3; i++) {...media(900, i), 'id': 'legacy_$i'},
  ];
  check(
    rows(unknownIds).length == 3,
    'Unrelated legacy media is not grouped by guesswork',
  );

  final longHistory = [
    for (var batch = 1000; batch < 2000; batch++)
      for (var index = 0; index < 14; index++) media(batch, index),
  ];
  final longRows = rows(longHistory);
  check(
    longRows.length == 1000 &&
        longRows.fold<int>(0, (count, row) => count + row.indexes.length) ==
            14000,
    'Large histories preserve every media item',
  );
  print('Chat media grouping checks passed ($_checks checks)');
}
