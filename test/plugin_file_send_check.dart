import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:skytide/plugin_chat_session.dart';
import 'package:skytide/plugin_file_store.dart';
import 'package:skytide/plugin_media_contract.dart';
import 'plugin_chat_session_check.dart' show Host, check, rejects;

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('tide-files-test-');
  final host = Host(root);
  final files = PluginFileStore(
    Directory(p.join(root.path, 'private')),
    check: () async {},
    locked: <T>(work) => work(),
  );
  final sessions = <PluginChatSession>[];
  PluginChatSession session() {
    final s = PluginChatSession(
      pluginId: 'test.files',
      botId: 'a',
      host: host,
      files: files,
      assertCurrent: () async {},
    );
    sessions.add(s);
    return s;
  }

  const permissions = ['chat.send', 'network', 'media.download', 'files'];
  Future<dynamic> call(
    PluginChatSession s,
    String method,
    Map<String, dynamic> args, {
    List access = permissions,
  }) => s.call(method, args, access, ['https://cdn.example.com']);
  try {
    final s = session();
    host.respond = (_) async => http.Response.bytes([80, 75, 3, 4, 0], 200);
    final zip = await call(s, 'chat.sendFile', {
      'url': 'https://cdn.example.com/archive.zip',
      'requestId': 'zip',
    });
    final row = host.rows[zip['messageId']]!;
    check(row['type'] == 'file', 'ZIP uses file message type');
    check(
      p.basename(row['file_path']) == 'archive.zip',
      'URL filename preserved',
    );
    check(
      (await File(row['file_path']).readAsBytes()).length == 5,
      'ZIP bytes preserved',
    );
    final duplicate = await call(s, 'chat.sendFile', {
      'url': 'https://cdn.example.com/archive.zip',
      'requestId': 'zip',
    });
    check(duplicate['duplicate'] == true, 'file request deduplication');
    await rejects(
      () => call(s, 'chat.sendDocument', {
        'url': 'https://cdn.example.com/archive.zip',
        'requestId': 'not-pdf',
      }),
      'document remains PDF only',
    );
    for (final name in [
      '../x.zip',
      '/x',
      r'a\b',
      '.',
      '..',
      '',
      'x\n.zip',
      'x\u0000.zip',
      ' x',
    ]) {
      await rejects(
        () async => PluginMediaContract.fileName(name),
        'invalid name $name',
      );
    }
    final local = await files.file('folder/测试.dat');
    await local.parent.create(recursive: true);
    await local.writeAsBytes([0, 1, 2]);
    final resource = await call(s, 'media.fromFile', {
      'path': 'folder/测试.dat',
      'kind': 'file',
    });
    final sent = await call(s, 'chat.sendFile', {
      'resourceId': resource['resourceId'],
      'requestId': 'local',
    });
    check(
      p.basename(host.rows[sent['messageId']]!['file_path']) == '测试.dat',
      'private file name preserved',
    );
    host.respond = (_) async => http.Response.bytes([73, 68, 51, 0, 0], 200);
    final audio = await call(s, 'media.download', {
      'url': 'https://cdn.example.com/music.mp3',
      'kind': 'audio',
    });
    final voice = await call(s, 'chat.sendAudio', {
      'resourceId': audio['resourceId'],
      'duration': 12,
      'requestId': 'voice',
    });
    check(
      host.rows[voice['messageId']]!['type'] == 'audio',
      'audio voice message',
    );
    check(host.rows[voice['messageId']]!['duration'] == 12, 'voice duration');
    final audioFile = await call(s, 'chat.sendFile', {
      'resourceId': audio['resourceId'],
      'fileName': '音乐.mp3',
      'requestId': 'audio-file',
    });
    check(
      host.rows[audioFile['messageId']]!['type'] == 'file',
      'same audio as file',
    );
    check(
      p.basename(host.rows[audioFile['messageId']]!['file_path']) == '音乐.mp3',
      'audio attachment filename',
    );
    final direct = await call(session(), 'chat.sendFile', {
      'url': 'https://cdn.example.com/music.mp3',
      'requestId': 'direct-audio',
    });
    check(
      host.rows[direct['messageId']]!['type'] == 'file',
      'direct audio remains file',
    );
    await rejects(
      () => call(
        session(),
        'chat.sendFile',
        {'url': 'https://cdn.example.com/a.zip', 'requestId': 'denied'},
        access: ['network', 'media.download'],
      ),
      'chat permission',
    );
    await rejects(
      () => call(
        session(),
        'chat.sendFile',
        {'url': 'https://cdn.example.com/a.zip', 'requestId': 'no-network'},
        access: ['chat.send', 'media.download'],
      ),
      'network permission',
    );
    await rejects(
      () => call(
        session(),
        'media.fromFile',
        {'path': 'folder/测试.dat', 'kind': 'file'},
        access: ['media.download'],
      ),
      'private file permission',
    );
    final oversized = await files.file('large.bin');
    final handle = await oversized.open(mode: FileMode.write);
    await handle.truncate(PluginMediaContract.limits['file']! + 1);
    await handle.close();
    await rejects(
      () => call(session(), 'media.fromFile', {
        'path': 'large.bin',
        'kind': 'file',
      }),
      'file size limit',
    );
    await s.close();
    check(
      await File(row['file_path']).exists(),
      'sent attachment survives session cleanup',
    );
    print('Plugin general file checks passed');
  } finally {
    for (final s in sessions) {
      await s.close();
    }
    await root.delete(recursive: true);
  }
}
