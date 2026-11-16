import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

/// Persistent files are separate from the immutable installed package.
class PluginFileStore {
  PluginFileStore(this.root, {required this.check, required this.locked});
  final Directory root;
  final Future<void> Function() check;
  final Future<T> Function<T>(Future<T> Function()) locked;
  static const maxFile = 256 * 1024 * 1024;
  static const quota = 512 * 1024 * 1024;
  static const chunkSize = 384 * 1024;

  Future<File> file(Object? name) async {
    if (name is! String ||
        name.isEmpty ||
        name.length > 512 ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('\x00') ||
        p.isAbsolute(name) ||
        name
            .split('/')
            .any(
              (v) =>
                  v.isEmpty ||
                  v == '.' ||
                  v == '..' ||
                  v.startsWith('.pending-'),
            )) {
      throw const FormatException('文件路径必须为插件私有目录内的相对路径');
    }
    await check();
    await root.create(recursive: true);
    var current = root.path;
    for (final part in name.split('/')) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link)
        throw const FormatException('不支持符号链接');
    }
    return File(current);
  }

  Future<int> _usage() async {
    var size = 0, count = 0;
    await for (final item in root.list(recursive: true, followLinks: false)) {
      if (++count > 10000) throw StateError('插件文件条目超过 10000');
      if (item is File) {
        if (p.basename(item.path).startsWith('.pending-')) {
          await item.delete();
        } else {
          size += await item.length();
        }
      }
    }
    return size;
  }

  Future<Map<String, dynamic>> writeStream(
    Object? name,
    Stream<List<int>> stream, {
    bool append = false,
    Future<void> Function()? beforeCommit,
  }) => locked(() async {
    final target = await file(name);
    await target.parent.create(recursive: true);
    final pending = File(
      p.join(
        target.parent.path,
        '.pending-${Random.secure().nextInt(1 << 32)}',
      ),
    );
    final oldSize = await target.exists() ? await target.length() : 0;
    final used = await _usage() - oldSize;
    var size = 0;
    RandomAccessFile? output;
    try {
      output = await pending.open(mode: FileMode.write);
      Future<void> add(Stream<List<int>> source) async {
        await for (final chunk in source) {
          await check();
          size += chunk.length;
          if (size > maxFile || used + size > quota)
            throw StateError('文件超过 256 MiB 或插件文件总量超过 512 MiB');
          await output!.writeFrom(chunk);
        }
      }

      if (append && oldSize > 0) await add(target.openRead());
      await add(stream);
      await output.flush();
      await output.close();
      output = null;
      await check();
      await beforeCommit?.call();
      await pending.rename(target.path);
      return {'path': name, 'size': size};
    } finally {
      await output?.close();
      if (await pending.exists()) await pending.delete();
    }
  });

  Future<dynamic> call(String method, Map args) async {
    if (method == 'files.write') {
      final encoding = args['encoding'] ?? 'utf8';
      final data = args['data'];
      if (data is! String || !{'utf8', 'base64'}.contains(encoding))
        throw const FormatException('data/encoding 无效');
      final bytes = encoding == 'base64'
          ? base64Decode(data)
          : utf8.encode(data);
      if (bytes.length > chunkSize)
        throw const FormatException('单次写入最多 384 KiB，请分块追加');
      return writeStream(
        args['path'],
        Stream.value(bytes),
        append: args['append'] == true,
      );
    }
    return locked(() async {
      await check();
      if (method == 'files.list') {
        final prefix = args['directory'];
        final directory = prefix == null || prefix == ''
            ? root
            : Directory((await file('$prefix/_')).parent.path);
        if (!await directory.exists()) return <dynamic>[];
        final results = <Map<String, dynamic>>[];
        await for (final item in directory.list(followLinks: false)) {
          if (p.basename(item.path).startsWith('.pending-')) continue;
          final stat = await item.stat();
          results.add({
            'path': p.relative(item.path, from: root.path),
            'type': stat.type == FileSystemEntityType.directory
                ? 'directory'
                : 'file',
            'size': stat.size,
          });
          if (results.length > 1000) throw StateError('目录最多返回 1000 项，请使用子目录');
        }
        await check();
        return results;
      }
      final target = await file(args['path']);
      if (method == 'files.stat') {
        if (!await target.exists()) return null;
        final stat = await target.stat();
        return {
          'path': args['path'],
          'size': stat.size,
          'modifiedAt': stat.modified.millisecondsSinceEpoch,
        };
      }
      if (method == 'files.delete') {
        if (!await target.exists()) return false;
        await target.delete();
        return true;
      }
      if (method == 'files.read') {
        final offset = args['offset'] ?? 0,
            length = args['length'] ?? chunkSize;
        final encoding = args['encoding'] ?? 'utf8';
        if (offset is! int ||
            offset < 0 ||
            length is! int ||
            length < 1 ||
            length > chunkSize ||
            !{'utf8', 'base64'}.contains(encoding))
          throw const FormatException('offset/length/encoding 无效');
        final handle = await target.open();
        try {
          await handle.setPosition(offset);
          final bytes = await handle.read(length);
          await check();
          return {
            'data': encoding == 'base64'
                ? base64Encode(bytes)
                : utf8.decode(bytes),
            'size': bytes.length,
            'eof': offset + bytes.length >= await handle.length(),
          };
        } finally {
          await handle.close();
        }
      }
      throw StateError('未知文件 API');
    });
  }
}
