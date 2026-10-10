import 'key_value_store.dart';

/// Where the ZARI API lives. Defaults to the build-time value
/// (`--dart-define=ZARI_API_URL=https://zari.example.coop`), and can be
/// changed from the login screen so one APK works across branches/LANs.
class AppConfig {
  AppConfig(this._kv, this._baseUrl);

  static const _key = 'zari.apiBaseUrl';

  /// 10.0.2.2 is the Android emulator's alias for the host machine, where the
  /// ZARI API's "http://0.0.0.0:5000" launch profile listens during dev.
  static const defaultBaseUrl = String.fromEnvironment('ZARI_API_URL', defaultValue: 'http://10.0.2.2:5000');

  final KeyValueStore _kv;
  String _baseUrl;

  String get baseUrl => _baseUrl;

  static Future<AppConfig> load(KeyValueStore kv) async => AppConfig(kv, await kv.read(_key) ?? defaultBaseUrl);

  Future<void> setBaseUrl(String value) async {
    _baseUrl = value.trim().replaceAll(RegExp(r'/+$'), '');
    await _kv.write(_key, _baseUrl);
  }
}
