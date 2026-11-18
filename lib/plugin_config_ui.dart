import 'dart:convert';

/// Presentation metadata for plugin configuration schemas.
class PluginConfigUi {
  static const widgets = {
    'provider',
    'bot',
    'multiline',
    'file',
    'directory',
    'date',
    'time',
    'timezone',
    'slider',
  };
  static Map ui(Map field) => field['x-ui'] as Map? ?? const {};
  static bool visible(Map field, Map values) {
    final when = ui(field)['visibleWhen'] as Map?;
    return when == null ||
        when.entries.every(
          (entry) => jsonEncode(values[entry.key]) == jsonEncode(entry.value),
        );
  }

  static void validate(Map field) {
    final raw = field.containsKey('x-ui')
        ? field['x-ui']
        : const <String, dynamic>{};
    if (raw is! Map) throw const FormatException('x-ui 必须为对象');
    const allowed = {
      'widget',
      'group',
      'collapsed',
      'unit',
      'providerTypes',
      'visibleWhen',
      'rows',
      'step',
      'extensions',
      'testAction',
      'testLabel',
    };
    if (raw.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('x-ui 包含不支持的选项');
    }
    for (final key in ['widget', 'group', 'unit', 'testAction', 'testLabel']) {
      if (raw[key] != null &&
          (raw[key] is! String || (raw[key] as String).trim().isEmpty)) {
        throw FormatException('x-ui.$key 必须为非空文本');
      }
    }
    if (raw['collapsed'] != null && raw['collapsed'] is! bool) {
      throw const FormatException('x-ui.collapsed 必须为布尔值');
    }
    final widget = raw['widget'];
    if (widget != null && !widgets.contains(widget)) {
      throw const FormatException('x-ui.widget 不支持');
    }
    if (raw['visibleWhen'] != null && raw['visibleWhen'] is! Map) {
      throw const FormatException('visibleWhen 必须为字段与值的对象');
    }
    if (field['type'] == 'object' && field['properties'] is Map) {
      final properties = field['properties'] as Map;
      for (final entry in properties.entries) {
        final child = entry.value;
        if (child is! Map) continue;
        final childUi = child['x-ui'];
        final when = childUi is Map ? childUi['visibleWhen'] : null;
        if (when is Map) {
          for (final key in when.keys) {
            if (!properties.containsKey(key) || key == entry.key) {
              throw const FormatException('visibleWhen 必须引用其他同级字段');
            }
          }
        }
      }
    }
    if (field['type'] == 'object' && field['properties'] is Map) {
      final props = field['properties'] as Map;
      final done = <String>{}, visiting = <String>{};
      void visit(String key) {
        if (done.contains(key)) return;
        if (!visiting.add(key))
          throw const FormatException('visibleWhen 不允许循环依赖');
        final child = props[key];
        if (child is Map && child['x-ui'] is Map) {
          final when = child['x-ui']['visibleWhen'];
          if (when is Map)
            for (final dependency in when.keys) {
              visit(dependency as String);
            }
        }
        visiting.remove(key);
        done.add(key);
      }

      for (final key in props.keys.cast<String>()) {
        visit(key);
      }
    }
    if (widget != null && field.containsKey('enum')) {
      throw const FormatException('自定义控件不能同时声明 enum');
    }
    if (widget == 'provider' || widget == 'bot') {
      if (field['type'] != 'string' &&
          !(field['type'] == 'array' &&
              field['items'] is Map &&
              field['items']['type'] == 'string')) {
        throw const FormatException('动态选择器必须使用 string 或 string 数组');
      }
      if (field.containsKey('enum'))
        throw const FormatException('动态选择器不能声明 enum');
    } else if (widget == 'slider') {
      if (!{'integer', 'number'}.contains(field['type']) ||
          field['minimum'] is! num ||
          field['maximum'] is! num ||
          field['minimum'] >= field['maximum']) {
        throw const FormatException('slider 必须声明有效的数字最小值和最大值');
      }
    } else if (widget != null && field['type'] != 'string') {
      throw const FormatException('此控件必须使用 string 字段');
    }
    if (field['format'] == 'password' &&
        (widget != null || field['type'] != 'string')) {
      throw const FormatException('password 仅适用于单行文本输入');
    }
    if (raw['providerTypes'] != null) {
      final types = raw['providerTypes'];
      if (widget != 'provider' ||
          types is! List ||
          types.isEmpty ||
          types.any((t) => !{'chat', 'stt', 'tts'}.contains(t)) ||
          types.toSet().length != types.length) {
        throw const FormatException('providerTypes 必须从 chat/stt/tts 中选择且不重复');
      }
    }
    if (raw['rows'] != null &&
        (widget != 'multiline' ||
            raw['rows'] is! int ||
            raw['rows'] < 2 ||
            raw['rows'] > 20)) {
      throw const FormatException('multiline rows 必须为 2 至 20');
    }
    if (widget == 'slider' &&
        field['type'] == 'integer' &&
        ((field['minimum'] as num) % 1 != 0 ||
            (field['maximum'] as num) % 1 != 0)) {
      throw const FormatException('整数滑块范围必须为整数');
    }
    final sliderStep =
        raw['step'] ??
        (widget == 'slider' && field['type'] == 'integer' ? 1 : null);
    if (sliderStep != null) {
      final step = sliderStep;
      if (widget != 'slider' ||
          step is! num ||
          !step.isFinite ||
          step <= 0 ||
          (field['type'] == 'integer' && step != step.roundToDouble())) {
        throw const FormatException('slider step 必须为有效正数，整数控件须使用整数步长');
      }
      final divisions = (field['maximum'] - field['minimum']) / step;
      if ((divisions - divisions.round()).abs() > 0.000001 ||
          divisions > 10000) {
        throw const FormatException('step 必须整除范围，且不超过 10000 档');
      }
    }
    if (raw['extensions'] != null &&
        (widget != 'file' ||
            raw['extensions'] is! List ||
            (raw['extensions'] as List).isEmpty ||
            (raw['extensions'] as List).any(
              (e) => e is! String || !RegExp(r'^[a-zA-Z0-9]+$').hasMatch(e),
            ))) {
      throw const FormatException('file extensions 必须为不带点的扩展名数组');
    }
    if (raw['testAction'] != null &&
        (field['type'] != 'object' ||
            !RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(raw['testAction']))) {
      throw const FormatException('testAction 必须在配置根对象声明有效动作名称');
    }
  }

  static void validateValue(Object key, dynamic value, Map field) {
    final metadata = ui(field), kind = metadata['widget'];
    if ((kind == 'provider' || kind == 'bot') &&
        value is List &&
        value.toSet().length != value.length) {
      throw FormatException('$key 不允许重复选择');
    }
    if (kind == 'slider' && value is num) {
      final step =
          metadata['step'] as num? ?? (field['type'] == 'integer' ? 1 : null);
      if (step != null) {
        final n = (value - field['minimum']) / step;
        if ((n - n.round()).abs() > .000001)
          throw FormatException('$key 不符合步长');
      }
    }
    if (value is! String || value.isEmpty) return;
    if (kind == 'date') {
      final date = DateTime.tryParse(value);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
          date == null ||
          date.toIso8601String().substring(0, 10) != value) {
        throw FormatException('$key 日期无效，必须为 YYYY-MM-DD');
      }
    }
    if (kind == 'time' &&
        !RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(value)) {
      throw FormatException('$key 时间无效，必须为 HH:mm');
    }
    if ((kind == 'file' || kind == 'directory') &&
        (value.startsWith('/') ||
            value.contains('\\') ||
            value.contains(':') ||
            value.contains('\x00') ||
            value
                .split('/')
                .any(
                  (p) =>
                      p.isEmpty ||
                      p == '.' ||
                      p == '..' ||
                      p.startsWith('.pending-'),
                ))) {
      throw FormatException('$key 必须为插件私有目录内的相对路径');
    }
  }
}
