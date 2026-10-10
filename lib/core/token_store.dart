import 'dart:convert';

import 'key_value_store.dart';

class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken, required this.userId});

  final String accessToken;
  final String refreshToken;
  final String userId;

  Map<String, dynamic> toJson() => {'accessToken': accessToken, 'refreshToken': refreshToken, 'userId': userId};

  factory AuthTokens.fromJson(Map<String, dynamic> json) => AuthTokens(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        userId: json['userId'] as String,
      );
}

/// Mirrors ZARI-FE's tokenStore.ts: the JWT + refresh token pair, kept in the
/// platform keystore instead of localStorage, with an in-memory copy so the
/// HTTP interceptor can read it synchronously.
class TokenStore {
  TokenStore(this._kv);

  static const _key = 'zari.auth.tokens';
  final KeyValueStore _kv;
  AuthTokens? _tokens;

  AuthTokens? get current => _tokens;

  Future<void> load() async {
    final raw = await _kv.read(_key);
    _tokens = raw == null ? null : AuthTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(AuthTokens tokens) async {
    _tokens = tokens;
    await _kv.write(_key, jsonEncode(tokens.toJson()));
  }

  Future<void> clear() async {
    _tokens = null;
    await _kv.delete(_key);
  }
}
