import 'dart:io';

/// Try each mirror until its response has been fully read and validated.
Future<T> readMarketRoute<T>({
  required Iterable<Uri> routes,
  required Future<T> Function(HttpClientResponse) read,
  required Duration timeout,
  required Duration connectionTimeout,
  Set<int> acceptedStatusCodes = const {HttpStatus.ok},
  void Function(HttpClientRequest)? configure,
  void Function()? checkCancelled,
  void Function()? Function(void Function())? listenForCancellation,
}) async {
  Object? lastError;
  for (final route in routes) {
    checkCancelled?.call();
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    void Function()? unlisten;
    try {
      unlisten = listenForCancellation?.call(() => client.close(force: true));
      final request = await client.getUrl(route).timeout(timeout);
      configure?.call(request);
      final response = await request.close().timeout(timeout);
      if (!acceptedStatusCodes.contains(response.statusCode)) {
        throw HttpException('HTTP ${response.statusCode}', uri: route);
      }
      final result = await read(response);
      checkCancelled?.call();
      return result;
    } catch (error) {
      checkCancelled?.call();
      lastError = error;
    } finally {
      unlisten?.call();
      client.close(force: true);
    }
  }
  throw lastError ?? const HttpException('没有可用的下载线路');
}
