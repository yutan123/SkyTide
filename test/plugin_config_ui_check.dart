import 'package:skytide/plugin_contract.dart';
import 'package:skytide/plugin_config_ui.dart';
import 'package:skytide/plugin_ai.dart';

void main() {
  var checks = 0;
  void expect(bool value) {
    if (!value) throw StateError('Check ${checks + 1} failed');
    checks++;
  }

  void rejects(void Function() work) {
    try {
      work();
    } on FormatException {
      checks++;
      return;
    }
    throw StateError('Expected FormatException at ${checks + 1}');
  }

  Map<String, dynamic> schema(Map<String, dynamic> field) => {
    'type': 'object',
    'properties': {'value': field},
  };
  for (final source in ['bot', 'provider']) {
    for (final multi in [false, true]) {
      final field = <String, dynamic>{
        'type': multi ? 'array' : 'string',
        if (multi) 'items': {'type': 'string'},
        'x-ui': {
          'widget': source,
          if (source == 'provider') 'providerTypes': ['chat', 'stt', 'tts'],
        },
      };
      final s = schema(field);
      final value = multi ? ['id-1', 'id-2'] : 'id-1';
      expect(
        PluginContract.values(s, {'value': value})['value'].toString() ==
            value.toString(),
      );
      if (multi)
        rejects(
          () => PluginContract.values(s, {
            'value': ['same', 'same'],
          }),
        );
    }
  }
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'integer',
        'x-ui': {'widget': 'bot'},
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {
          'widget': 'provider',
          'providerTypes': ['unknown'],
        },
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {
          'widget': 'provider',
          'providerTypes': ['chat', 'chat'],
        },
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'array',
        'items': {'type': 'integer'},
        'x-ui': {'widget': 'provider'},
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {'widget': 'unknown'},
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {'widget': 'multiline', 'rows': 30},
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'format': 'password',
        'x-ui': {'widget': 'multiline'},
      }),
    ),
  );
  final conditional = <String, dynamic>{
    'type': 'object',
    'properties': {
      'enabled': {'type': 'boolean', 'default': false},
      'provider': {
        'type': 'string',
        'x-ui': {
          'widget': 'provider',
          'visibleWhen': {'enabled': true},
        },
      },
    },
    'required': ['provider'],
  };
  expect(!PluginContract.values(conditional, {}).containsKey('provider'));
  rejects(() => PluginContract.values(conditional, {'enabled': true}));
  expect(
    PluginContract.values(conditional, {
          'enabled': true,
          'provider': 'a',
        })['provider'] ==
        'a',
  );
  expect(
    PluginContract.values(conditional, {
          'enabled': false,
          'provider': 'a',
        })['provider'] ==
        'a',
  );
  expect(
    PluginConfigUi.visible((conditional['properties'] as Map)['provider'], {
      'enabled': true,
    }),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {
          'visibleWhen': {'missing': true},
        },
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {
          'visibleWhen': {'value': true},
        },
      }),
    ),
  );
  rejects(
    () => PluginContract.schema({
      'type': 'object',
      'properties': {
        'a': {
          'type': 'boolean',
          'x-ui': {
            'visibleWhen': {'b': true},
          },
        },
        'b': {
          'type': 'boolean',
          'x-ui': {
            'visibleWhen': {'a': true},
          },
        },
      },
    }),
  );
  final slider = schema({
    'type': 'integer',
    'minimum': 0,
    'maximum': 60,
    'x-ui': {'widget': 'slider', 'step': 5, 'unit': '分钟'},
  });
  expect(PluginContract.values(slider, {'value': 15})['value'] == 15);
  rejects(() => PluginContract.values(slider, {'value': 16}));
  rejects(() => PluginContract.values(slider, {'value': 65}));
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'number',
        'minimum': 0,
        'maximum': 1,
        'x-ui': {'widget': 'slider', 'step': 0},
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'number',
        'minimum': 0,
        'maximum': 1,
        'x-ui': {'widget': 'slider', 'step': .3},
      }),
    ),
  );
  for (final pair in [
    ['date', '2024-02-29'],
    ['time', '23:59'],
    ['file', 'config_imports/cert.pem'],
    ['directory', 'attachments/mail'],
  ]) {
    expect(
      PluginContract.values(
            schema({
              'type': 'string',
              'x-ui': {'widget': pair[0]},
            }),
            {'value': pair[1]},
          )['value'] ==
          pair[1],
    );
  }
  for (final pair in [
    ['date', '2025-02-29'],
    ['date', '2025-13-01'],
    ['time', '24:00'],
    ['time', '3:20'],
    ['directory', '../mail'],
    ['file', '/sdcard/test.pem'],
    ['file', 'a/.pending-x'],
    ['file', 'a\\b'],
  ]) {
    rejects(
      () => PluginContract.values(
        schema({
          'type': 'string',
          'x-ui': {'widget': pair[0]},
        }),
        {'value': pair[1]},
      ),
    );
  }
  rejects(
    () => PluginContract.schema(
      schema({
        'type': 'string',
        'x-ui': {
          'widget': 'file',
          'extensions': ['.pem'],
        },
      }),
    ),
  );
  rejects(
    () => PluginContract.schema(schema({'type': 'string', 'x-ui': null})),
  );
  for (final bounds in [
    [0.5, 10.5],
    [0, 10001],
  ]) {
    rejects(
      () => PluginContract.schema(
        schema({
          'type': 'integer',
          'minimum': bounds[0],
          'maximum': bounds[1],
          'x-ui': {'widget': 'slider'},
        }),
      ),
    );
  }
  for (final kind in [
    'file',
    'directory',
    'date',
    'time',
    'timezone',
    'multiline',
  ]) {
    rejects(
      () => PluginContract.schema(
        schema({
          'type': 'string',
          'enum': ['a'],
          'x-ui': {'widget': kind},
        }),
      ),
    );
  }
  final nested = schema(conditional);
  expect(
    !(PluginContract.values(nested, {'value': {}})['value'] as Map).containsKey(
      'provider',
    ),
  );
  rejects(
    () => PluginContract.values(nested, {
      'value': {'enabled': true},
    }),
  );
  expect(
    PluginContract.values(nested, {
          'value': {'enabled': false, 'provider': 'retained'},
        })['value']['provider'] ==
        'retained',
  );
  final decimalSlider = schema({
    'type': 'number',
    'minimum': -1,
    'maximum': 1,
    'x-ui': {'widget': 'slider', 'step': 0.1},
  });
  expect(PluginContract.values(decimalSlider, {'value': 0.3})['value'] == 0.3);
  rejects(() => PluginContract.values(decimalSlider, {'value': 0.35}));
  expect(PluginAI.providerId({'id': 'provider-1'}).length == 64);
  expect(
    PluginAI.providerId({'id': 'provider-1', 'api_key': 'a'}) ==
        PluginAI.providerId({'id': 'provider-1', 'api_key': 'b'}),
  );
  expect(PluginContract.capabilities.contains('config.ui'));
  print('$checks plugin configuration checks passed');
}
