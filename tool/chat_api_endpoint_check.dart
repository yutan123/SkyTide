import 'package:tide_bot/chat_api_endpoint.dart';

void main() {
  const expected = 'https://api.deepseek.com/v1/chat/completions';
  for (final input in [
    'https://api.deepseek.com',
    'https://api.deepseek.com/',
    'https://api.deepseek.com/v1',
    'https://api.deepseek.com/v1/',
    'https://api.deepseek.com/v1/chat',
    'https://api.deepseek.com/v1/chat/',
    expected,
    '$expected/',
    '  $expected  ',
  ]) {
    if (chatApiEndpoint(input) != expected) throw StateError(input);
  }
  for (final input in [
    'https://gateway.example/compatible-mode/v1',
    'https://gateway.example/api/v3',
  ]) {
    if (chatApiEndpoint(input) != '$input/chat/completions') {
      throw StateError('Gateway prefix changed: $input');
    }
  }
  const query = 'https://api.deepseek.com/v1/chat?token=example';
  if (chatApiEndpoint(query) != '$expected?token=example') {
    throw StateError('Query was not preserved');
  }
  if (chatApiBase(expected) != 'https://api.deepseek.com/v1') {
    throw StateError('Model-list base is incorrect');
  }
  print('API endpoint regression checks passed.');
}
