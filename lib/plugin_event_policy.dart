/// Shared manifest validation and deterministic text command matching.
class PluginEventPolicy {
  static List<String> commands(Object? value) {
    if (value == null) return [];
    if (value is! List || value.length > 32)
      throw const FormatException('commands 最多声明 32 项');
    final names = <String>{};
    for (final name in value) {
      if (name is! String ||
          !RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(name) ||
          !names.add(name))
        throw const FormatException('command 名称无效或重复');
    }
    return names.toList();
  }

  static int priority(Object? value) {
    if (value == null) return 0;
    if (value is! int || value < -100 || value > 100)
      throw const FormatException('eventPriority 范围为 -100 至 100');
    return value;
  }

  static Map<String, String>? match(Object? content, List<String> names) {
    if (content is! String || content.length > 32768) return null;
    final match = RegExp(
      r'^/([a-z][a-z0-9_]{0,39})(?:\s+([\s\S]*))?$',
    ).firstMatch(content.trim());
    if (match == null || !names.contains(match[1])) return null;
    return {'name': match[1]!, 'text': match[2]?.trim() ?? ''};
  }
}
