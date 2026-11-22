/// Completes common OpenAI-compatible base URLs while retaining gateway prefixes.
String chatApiBase(String configured) {
  final text = configured.trim();
  final uri = Uri.parse(text);
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/chat/completions')) {
    path = path.substring(0, path.length - '/chat/completions'.length);
  } else if (path.endsWith('/responses')) {
    path = path.substring(0, path.length - '/responses'.length);
  } else if (path.endsWith('/chat')) {
    path = path.substring(0, path.length - '/chat'.length);
  }
  if (path.isEmpty) path = '/v1';
  return uri.replace(path: path).toString();
}

String chatApiEndpoint(String configured) {
  final original = Uri.parse(configured.trim());
  final path = original.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/chat/completions')) {
    return original.replace(path: path).toString();
  }
  final uri = Uri.parse(chatApiBase(configured));
  return uri.replace(path: '${uri.path}/chat/completions').toString();
}
