import 'dart:convert';

import 'package:crypto/crypto.dart';

enum ChatProviderCache {
  compatible,
  gpt,
  grok,
  claude,
  gemini,
  deepSeek,
  mimo,
  miniMax,
  siliconFlow,
  dashScope,
  kimi,
  gitee;

  static const _presets = {
    'ChatGPT': gpt,
    'Grok': grok,
    'Claude': claude,
    'Gemini': gemini,
    'DeepSeek': deepSeek,
    'Mimo': mimo,
    'MiniMax': miniMax,
    'SiliconFlow': siliconFlow,
    '阿里云百炼': dashScope,
    'Kimi': kimi,
    'Gitee AI': gitee,
  };

  static ChatProviderCache resolve(Map provider) {
    if (provider['is_custom'] == true) return compatible;
    return _presets[provider['preset_name'] ?? provider['name']] ?? compatible;
  }

  Map<String, String> requestHeaders(String scope) => {
    if (this == grok)
      'x-grok-conv-id': sha256.convert(utf8.encode(scope)).toString(),
  };

  Map<String, dynamic> requestOptions(String scope, {required bool stream}) {
    return {
      if (stream && (this == compatible || this == grok || this == dashScope))
        'stream_options': {'include_usage': true},
    };
  }

  ({int? hit, int? miss, int? written}) usage(Map usage) {
    int? tokens(Object? value) => value is int && value >= 0 ? value : null;
    final details = usage['prompt_tokens_details'];
    final standard = details is Map ? tokens(details['cached_tokens']) : null;
    final inputDetails = usage['input_tokens_details'];
    final responses = inputDetails is Map
        ? tokens(inputDetails['cached_tokens'])
        : null;
    final hit = switch (this) {
      deepSeek => tokens(usage['prompt_cache_hit_tokens']),
      kimi => standard ?? tokens(usage['cached_tokens']),
      miniMax => standard ?? tokens(usage['cache_read_input_tokens']),
      gpt => responses ?? standard ?? tokens(usage['cached_tokens']),
      compatible ||
      grok ||
      claude ||
      gemini ||
      mimo ||
      dashScope ||
      siliconFlow ||
      gitee => standard,
    };
    final total =
        tokens(usage['prompt_tokens']) ?? tokens(usage['input_tokens']);
    return (
      hit: hit,
      miss: this == deepSeek
          ? tokens(usage['prompt_cache_miss_tokens'])
          : (total != null && hit != null && hit <= total ? total - hit : null),
      written: this == gpt
          ? (inputDetails is Map
                    ? tokens(inputDetails['cache_write_tokens'])
                    : null) ??
                (details is Map ? tokens(details['cache_write_tokens']) : null)
          : this == miniMax || this == claude
          ? tokens(usage['cache_creation_input_tokens'])
          : null,
    );
  }
}
