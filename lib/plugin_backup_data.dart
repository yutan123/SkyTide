/// Portable plugin data. Device grants and runtime leases are not transferable.
class PluginBackupData {
  static const restoredMarker = 'plugin_backup_data_v1';
  static const directoryList = 'private_directories';
  static const privateFiles = 'plugin_files';
  static const _prefixes = [
    'plugin_config_',
    'plugin_data_',
    'plugin_bot_data_',
    'plugin_prompts_',
    'plugin_credentials_',
  ];
  static const supportDirectories = ['plugins', 'skills', privateFiles];

  static Set<String> keysFor(Iterable<String> ids) => {
    for (final id in ids)
      for (final prefix in _prefixes) '$prefix$id',
  };

  static bool isSafeDirectory(String path) =>
      !path.contains('\\') &&
      !path.contains('\u0000') &&
      path
          .split('/')
          .every(
            (part) =>
                part.isNotEmpty &&
                part != '.' &&
                part != '..' &&
                !part.startsWith('.pending-'),
          );

  static bool isStorageKey(String key) => _prefixes.any(
    (prefix) => key.startsWith(prefix) && key.length > prefix.length,
  );
}
