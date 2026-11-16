import 'dart:convert';
import 'package:flutter/material.dart';

import 'plugin_contract.dart';
import 'theme.dart';
import 'ui_components.dart';

class PluginConfigDialog extends StatefulWidget {
  final String title;
  final Map schema;
  final Map<String, dynamic> values;
  const PluginConfigDialog({
    super.key,
    required this.title,
    required this.schema,
    required this.values,
  });
  @override
  State<PluginConfigDialog> createState() => _PluginConfigDialogState();
}

class _PluginConfigDialogState extends State<PluginConfigDialog> {
  final _controllers = <String, TextEditingController>{};
  final _values = <String, dynamic>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    final properties = widget.schema['properties'] as Map;
    for (final key in properties.keys.cast<String>()) {
      final field = properties[key] as Map;
      final value = widget.values[key] ?? field['default'];
      if (field['type'] == 'boolean' && field['enum'] is! List) {
        _values[key] = value ?? false;
      } else if (field['enum'] is List &&
          !{'object', 'array'}.contains(field['type'])) {
        if (value != null) _values[key] = value;
      } else {
        _controllers[key] = TextEditingController(
          text: value == null
              ? ''
              : ({'object', 'array'}.contains(field['type'])
                    ? const JsonEncoder.withIndent('  ').convert(value)
                    : value.toString()),
        );
      }
    }
  }

  void _save() {
    try {
      final values = <String, dynamic>{
        if (widget.schema['additionalProperties'] == true)
          for (final entry in widget.values.entries)
            if (!(widget.schema['properties'] as Map).containsKey(entry.key))
              entry.key: entry.value,
        ..._values,
      };
      final properties = widget.schema['properties'] as Map;
      for (final entry in _controllers.entries) {
        final type = properties[entry.key]['type'];
        final text = entry.value.text;
        if (text.isEmpty && type != 'string') continue;
        values[entry.key] = switch (type) {
          'integer' => int.parse(text),
          'number' => double.parse(text),
          'object' || 'array' => jsonDecode(text),
          _ => text,
        };
      }
      Navigator.pop(context, PluginContract.values(widget.schema, values));
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final properties = widget.schema['properties'] as Map;
    final theme = TideTheme.of(context);
    final materialTheme = Theme.of(context);
    return Theme(
      data: materialTheme.copyWith(
        colorScheme: materialTheme.colorScheme.copyWith(
          primary: theme.primary,
          onPrimary: Colors.white,
          surface: theme.surface,
          onSurface: theme.textStrong,
        ),
      ),
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: TideDialogSurface(
          title: Text(
            widget.title,
            style: TextStyle(
              color: theme.textStrong,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFamily: 'TideFont',
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final key in properties.keys.cast<String>())
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _field(key, properties[key] as Map),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: materialTheme.colorScheme.error),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _decoration(String title, Map field) {
    final theme = TideTheme.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: theme.textFaint.withValues(alpha: .25)),
    );
    return InputDecoration(
      labelText: title,
      labelStyle: TextStyle(color: theme.textWeak),
      helperText: field['description']?.toString(),
      helperStyle: TextStyle(color: theme.textWeak, fontSize: 12),
      helperMaxLines: 4,
      filled: true,
      fillColor: theme.surfaceVariant.withValues(alpha: .45),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: theme.primary, width: 1.5),
      ),
    );
  }

  Future<void> _selectOption(String key, String title, List options) async {
    FocusScope.of(context).unfocus();
    final theme = TideTheme.of(context);
    final selected = options.indexWhere(
      (option) => jsonEncode(option) == jsonEncode(_values[key]),
    );
    final index = await TideDialogs.show<int>(
      context: context,
      builder: (ctx) => TideDialogSurface(
        title: Text(
          title,
          style: TextStyle(
            color: theme.textStrong,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            fontFamily: 'TideFont',
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < options.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: i == selected
                          ? theme.primary.withValues(alpha: .12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => Navigator.pop(ctx, i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 13,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  options[i].toString(),
                                  style: TextStyle(
                                    color: i == selected
                                        ? theme.primary
                                        : theme.textStrong,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                i == selected
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                color: i == selected
                                    ? theme.primary
                                    : theme.textFaint,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: theme.primary),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || index == null) return;
    setState(() => _values[key] = options[index]);
  }

  Widget _field(String key, Map field) {
    final theme = TideTheme.of(context);
    final title = field['title']?.toString() ?? key;
    if (field['enum'] is List && !{'object', 'array'}.contains(field['type'])) {
      final options = field['enum'] as List;
      // Compare encoded values to preserve distinct integer and decimal entries.
      final selected = options.indexWhere(
        (option) => jsonEncode(option) == jsonEncode(_values[key]),
      );
      return Semantics(
        button: true,
        label: title,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _selectOption(key, title, options),
          child: InputDecorator(
            decoration: _decoration(title, field),
            isEmpty: selected < 0,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selected < 0 ? '' : options[selected].toString(),
                    style: TextStyle(color: theme.textStrong, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.expand_more_rounded,
                  color: theme.textWeak,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (field['type'] == 'boolean') {
      final enabled = _values[key] as bool? ?? false;
      return Semantics(
        label: title,
        toggled: enabled,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _values[key] = !enabled),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(color: theme.textStrong, fontSize: 14),
                      ),
                      if (field['description'] != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          field['description'].toString(),
                          style: TextStyle(color: theme.textWeak, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 48,
                  height: 44,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 38,
                      height: 23,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: enabled ? theme.primary : theme.surfaceVariant,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: AnimatedAlign(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        alignment: enabled
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          width: 17,
                          height: 17,
                          decoration: BoxDecoration(
                            color: enabled ? Colors.white : theme.textWeak,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return TextField(
      controller: _controllers[key],
      style: TextStyle(color: theme.textStrong, fontSize: 14),
      cursorColor: theme.primary,
      obscureText: field['type'] == 'string' && field['format'] == 'password',
      minLines: {'object', 'array'}.contains(field['type']) ? 3 : 1,
      maxLines: {'object', 'array'}.contains(field['type']) ? 8 : 1,
      keyboardType: {'number', 'integer'}.contains(field['type'])
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: _decoration(title, field),
    );
  }
}
