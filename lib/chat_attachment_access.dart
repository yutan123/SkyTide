import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

bool isPluginChatMessage(Map<String, dynamic> row) =>
    row['role'] == 'assistant' &&
    (row['id']?.toString().startsWith('plugin_') ?? false);

bool isReadableChatHistoryRow(Map<String, dynamic> row) =>
    (row['role'] == 'user' || row['role'] == 'assistant') &&
    (row['error_log']?.toString().isEmpty ?? true) &&
    (row['error_code']?.toString().isEmpty ?? true);

class ChatFileReference {
  ChatFileReference(this.number, this.path)
    : name = p.basename(path).replaceAll(RegExp(r'[\r\n]'), ' ');

  final int number;
  final String path;
  final String name;

  String get label => '[文件#$number] $name';
}

class ChatAttachmentCatalog {
  final filesByMessageId = <String, ChatFileReference>{};
  final pluginVideosByMessageId = <String, String>{};
  final pluginVideoPaths = <String, String>{};

  void add(Map<String, dynamic> row) {
    if (!isReadableChatHistoryRow(row)) return;
    final id = row['id']?.toString() ?? '';
    final path = row['file_path']?.toString() ?? '';
    if (id.isEmpty || path.trim().isEmpty) return;
    final type = row['type'];
    if (type == 'file' || type == 'document') {
      filesByMessageId.putIfAbsent(
        id,
        () => ChatFileReference(filesByMessageId.length + 1, path),
      );
    } else if (type == 'video' && isPluginChatMessage(row)) {
      final videoId = 'VID-$id';
      pluginVideosByMessageId[id] = videoId;
      pluginVideoPaths[videoId] = path;
    }
  }
}

const chatFileTurnByteLimit = 10 * 1024 * 1024;

String? chatFileMimeType(String extension) => switch (extension) {
  '.doc' => 'application/msword',
  '.ppt' => 'application/vnd.ms-powerpoint',
  '.xls' => 'application/vnd.ms-excel',
  '.epub' => 'application/epub+zip',
  '.mobi' => 'application/x-mobipocket-ebook',
  '.pdf' => 'application/pdf',
  '.txt' || '.log' => 'text/plain',
  '.md' => 'text/markdown',
  '.csv' => 'text/csv',
  '.json' => 'application/json',
  '.docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx' =>
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pptx' =>
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  _ => null,
};

Future<Uint8List> readChatFileBytes(
  ChatFileReference file, {
  required int remainingBytes,
}) async {
  final source = File(file.path);
  if (!await source.exists()) {
    throw const FormatException('原文件不存在或已清理');
  }
  if (remainingBytes <= 0 || await source.length() > remainingBytes) {
    throw const FormatException('本轮原文件总量不能超过 10 MiB');
  }
  final handle = await source.open();
  final bytes = await (() async {
    try {
      return await handle.read(remainingBytes + 1);
    } finally {
      await handle.close();
    }
  })();
  if (bytes.isEmpty) throw const FormatException('原文件为空');
  if (bytes.length > remainingBytes) {
    throw const FormatException('本轮原文件总量不能超过 10 MiB');
  }
  return bytes;
}
