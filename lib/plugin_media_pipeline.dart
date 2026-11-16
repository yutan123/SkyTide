import 'dart:convert';
import 'dart:io';

/// Local-only FFmpeg plans: plugins select operations, never native paths/flags.
class PluginMediaPipeline {
  static List<String> arguments(
    Map options,
    List<String> inputs,
    String output,
  ) {
    final operation = options['operation'];
    final format = options['format'] ?? 'mp4';
    if (!{'mp4', 'webm', 'm4a', 'mp3', 'wav'}.contains(format))
      throw const FormatException('输出格式不支持');
    if (!{'merge', 'transcode', 'hls'}.contains(operation))
      throw const FormatException('媒体操作不支持');
    if (inputs.isEmpty ||
        inputs.length > 2 ||
        (operation == 'merge' && inputs.length != 2))
      throw const FormatException('媒体输入数量无效');
    if (operation == 'hls' && !{'mp4', 'm4a'}.contains(format))
      throw const FormatException('HLS 输出使用 mp4 或 m4a');
    if (operation == 'merge' && format != 'mp4')
      throw const FormatException('合并输出使用 mp4');
    return [
      '-nostdin',
      '-y',
      for (final input in inputs) ...[
        '-protocol_whitelist',
        'file,crypto,data',
        if (operation == 'hls') ...['-allowed_extensions', 'ALL'],
        '-i',
        input,
      ],
      if (operation == 'merge') ...['-map', '0:v:0', '-map', '1:a:0'],
      if (operation == 'hls') ...[
        if (format != 'm4a') ...['-map', '0:v:0?'],
        '-map',
        '0:a:0?',
      ],
      if (operation != 'transcode') ...[
        '-c',
        'copy',
      ] else if (format == 'mp4') ...[
        '-c:v',
        'mpeg4',
        '-q:v',
        '4',
        '-c:a',
        'aac',
      ] else if (format == 'webm') ...[
        '-c:v',
        'libvpx',
        '-c:a',
        'libvorbis',
      ] else if (format == 'mp3') ...[
        '-vn',
        '-c:a',
        'libmp3lame',
      ] else if (format == 'm4a') ...[
        '-vn',
        '-c:a',
        'aac',
      ] else ...[
        '-vn',
        '-c:a',
        'pcm_s16le',
      ],
      if (format == 'mp4' || format == 'm4a') ...['-movflags', '+faststart'],
      '-fs',
      '${256 * 1024 * 1024}',
      output,
    ];
  }

  /// Mirror VOD playlists, variants, keys and init segments before native work.
  /// FFmpeg receives only local URLs; every remote URL goes through host policy.
  static Future<String> hls({
    required String url,
    required Directory directory,
    required Future<String> Function(String url, File output) download,
    required Future<void> Function() check,
  }) async {
    final visited = <String, String>{};
    final active = <String>{};
    var total = 0;
    Future<String> mirror(
      String address,
      int depth, {
      bool playlist = false,
    }) async {
      if (active.contains(address)) throw const FormatException('HLS 清单存在循环引用');
      if (visited.containsKey(address)) return visited[address]!;
      if (depth > 8 || visited.length >= 2048)
        throw StateError('HLS 层级或分片数量超限');
      final name = 'h${visited.length}${playlist ? '.m3u8' : '.bin'}';
      visited[address] = name;
      if (playlist) active.add(address);
      final target = File('${directory.path}/$name');
      await check();
      final effectiveAddress = await download(address, target);
      total += await target.length();
      if (total > 256 * 1024 * 1024) throw StateError('HLS 总下载量超过 256 MiB');
      if (!playlist) return name;
      if (await target.length() > 1024 * 1024)
        throw StateError('HLS 清单超过 1 MiB');
      final text = await target.readAsString();
      if (!text.trimLeft().startsWith('#EXTM3U'))
        throw const FormatException('无效的 HLS 清单');
      final lines = const LineSplitter().convert(text);
      final master = lines.any((line) => line.startsWith('#EXT-X-STREAM-INF:'));
      if (!master && !lines.any((line) => line.trim() == '#EXT-X-ENDLIST'))
        throw const FormatException('HLS 需要已结束的点播清单');
      final output = <String>[];
      var chosenVariant = false, includeVariant = false;
      for (var line in lines) {
        line = line.trim();
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          includeVariant = !chosenVariant;
          if (!includeVariant) continue;
          chosenVariant = true;
        } else if (line.isNotEmpty && !line.startsWith('#')) {
          if (master && !includeVariant) continue;
          line = await mirror(
            Uri.parse(effectiveAddress).resolve(line).toString(),
            depth + 1,
            playlist: master,
          );
          includeVariant = false;
        } else if (line.contains('URI=') && !line.contains('URI="')) {
          throw const FormatException('HLS URI 必须使用双引号');
        } else if (line.contains('URI="')) {
          if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) continue;
          if (![
            '#EXT-X-KEY:',
            '#EXT-X-MAP:',
            '#EXT-X-MEDIA:',
          ].any(line.startsWith))
            throw const FormatException('不支持的 HLS URI 标签');
          if (line.startsWith('#EXT-X-KEY:') &&
              !RegExp(r'METHOD=AES-128(?:,|$)').hasMatch(line))
            throw const FormatException('仅支持 AES-128 HLS 加密');
          final match = RegExp('URI="([^"]+)"').firstMatch(line);
          if (match != null) {
            final child = await mirror(
              Uri.parse(effectiveAddress).resolve(match.group(1)!).toString(),
              depth + 1,
              playlist: line.startsWith('#EXT-X-MEDIA:'),
            );
            line = line.replaceRange(match.start, match.end, 'URI="$child"');
          }
        }
        if (line.contains('URI=') &&
            RegExp('URI=').allMatches(line).length != 1)
          throw const FormatException('HLS URI 属性重复');
        output.add(line);
      }
      active.remove(address);
      await target.writeAsString(output.join('\n'));
      return name;
    }

    return '${directory.path}/${await mirror(url, 0, playlist: true)}';
  }
}
