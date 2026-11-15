import 'dart:io';

/// Only globally routable addresses may be reached by untrusted image URLs.
bool isPublicImageAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (b.length == 4) {
    final a = b[0], c = b[1];
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && c >= 64 && c <= 127) ||
        (a == 169 && c == 254) ||
        (a == 172 && c >= 16 && c <= 31) ||
        (a == 192 && (c == 0 || c == 168 || (c == 88 && b[2] == 99))) ||
        (a == 198 && (c == 18 || c == 19 || (c == 51 && b[2] == 100))) ||
        (a == 203 && c == 0 && b[2] == 113));
  }
  // Accept native global unicast only. This also rejects mapped IPv4, NAT64,
  // local, multicast and unspecified addresses. Exclude transition and docs.
  if (b.length != 16 || (b[0] & 0xe0) != 0x20) return false;
  if (b[0] == 0x20 && b[1] == 0x02) return false; // 6to4
  if (b[0] == 0x20 &&
      b[1] == 0x01 &&
      ((b[2] <= 1) ||
          (b[2] == 0x0d && b[3] == 0xb8) ||
          (b[2] == 0x00 && b[3] == 0x02) ||
          (b[2] & 0xf0) == 0x10)) {
    return false;
  }
  if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0) return false;
  return true;
}

HttpClient publicImageHttpClient() {
  final client = HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 10);
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost != null ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const SocketException('图片地址不允许');
    }
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any((a) => !isPublicImageAddress(a))) {
      throw const SocketException('不允许访问本机或非公共网络图片地址');
    }
    // Connect to the validated address, never resolve the hostname a second
    // time. HttpClient retains the original hostname for TLS verification.
    return Socket.startConnect(addresses.first, uri.port);
  };
  return client;
}
