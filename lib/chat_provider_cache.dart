import 'dart:convert';

import 'package:crypto/crypto.dart';

enum ChatProviderCache {
  compatible,
  gpt,
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
    'Claude': (claude, 'api.anthropic.com'),
    'Gemini': (gemini, 'generativelanguage.googleapis.com'),
    'ChatGPT': (gpt, 'api.openai.com'),
    'DeepSeek': (deepSeek, 'api.deepseek.com'),
    'Mimo': (mimo, 'api.xiaomimimo.com'),
    'MiniMax': (miniMax, 'api.minimax.cn'),
    'SiliconFlow': (siliconFlow, 'api.siliconflow.cn'),
    '阿里云百炼': (dashScope, 'dashscope.aliyuncs.com'),
    'Kimi': (kimi, 'api.moonshot.cn'),
    'Gitee AI': (gitee, 'ai.gitee.com'),
  };

  static ChatProviderCache resolve(Map provider) {
    if (provider['is_custom'] == true) return compatible;
    final preset = _presets[provider['preset_name'] ?? provider['name']];
    final url = Uri.tryParse('${provider['base_url'] ?? ''}');
    if (preset == null || url?.host != preset.$2) return compatible;
    if (const {gpt, claude, gemini}.contains(preset.$1) &&
        (provider['preset_name'] == null ||
            url?.scheme != 'https' ||
            url?.port != 443 ||
            url?.userInfo.isNotEmpty == true)) {
      return compatible;
    }
    return preset.$1;
  }

  Map<String, dynamic> requestOptions(String scope, {required bool stream}) {
    return {
      if (this == gpt)
        'prompt_cache_key': sha256.convert(utf8.encode(scope)).toString(),
      if (stream && (this == compatible || this == gpt || this == dashScope))
        'stream_options': {'include_usage': true},
    };
  }

  ({int? hit, int? miss, int? written}) usage(Map usage) {
    int? tokens(Object? value) => value is int && value >= 0 ? value : null;
    final details = usage['prompt_tokens_details'];
    final standard = details is Map ? tokens(details['cached_tokens']) : null;
    final hit = switch (this) {
      deepSeek => tokens(usage['prompt_cache_hit_tokens']),
      kimi => standard ?? tokens(usage['cached_tokens']),
      miniMax => standard ?? tokens(usage['cache_read_input_tokens']),
      compatible ||
      gpt ||
      claude ||
      gemini ||
      mimo ||
      dashScope ||
      siliconFlow ||
      gitee => standard,
    };
    final total = tokens(usage['prompt_tokens']);
    return (
      hit: hit,
      miss: this == deepSeek
          ? tokens(usage['prompt_cache_miss_tokens'])
          : (total != null && hit != null && hit <= total ? total - hit : null),
      written: this == miniMax || this == claude
          ? tokens(usage['cache_creation_input_tokens'])
          : null,
    );
  }
}
