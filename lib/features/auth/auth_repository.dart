import 'dart:convert';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/key_value_store.dart';
import '../../core/token_store.dart';
import 'password_verifier.dart';
import 'session.dart';

class LoginResult {
  const LoginResult(this.session, {required this.offline, required this.userChanged});

  final UserSession session;

  /// Signed in against the cached verifier because ZARI was unreachable.
  final bool offline;

  /// A different user than the last one signed in on this device — the
  /// caller should wipe the master-data cache (it's scoped to their branches).
  final bool userChanged;
}

class AuthFailure implements Exception {
  AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class AuthRepository {
  AuthRepository({required ApiClient api, required TokenStore tokens, required KeyValueStore kv})
      : _api = api,
        _tokens = tokens,
        _kv = kv;

  final ApiClient _api;
  final TokenStore _tokens;
  final KeyValueStore _kv;

  static const _lastUserKey = 'zari.lastUserId';
  static const _activeKey = 'zari.activeUserId';
  static String _sessionKey(String userId) => 'zari.session.$userId';
  static String _verifierKey(String email) => 'zari.offline.${email.trim().toLowerCase()}';

  bool get hasTokens => _tokens.current != null;

  /// Online first; falls back to the cached verifier only when ZARI can't be
  /// reached. A wrong password online is never retried offline.
  Future<LoginResult> login(String email, String password) async {
    final trimmed = email.trim();
    Map<String, dynamic> token;
    try {
      token = await _api.post<Map<String, dynamic>>('/api/identity/login', {'email': trimmed, 'password': password});
    } on ApiException catch (e) {
      if (e.kind == ApiFailureKind.offline || e.kind == ApiFailureKind.ambiguous) {
        return _offlineLogin(trimmed, password);
      }
      if (e.statusCode == 400 || e.statusCode == 401) throw AuthFailure('Invalid email or password.');
      if (e.statusCode == 429) throw AuthFailure('Too many sign-in attempts. Wait a minute and try again.');
      throw AuthFailure(e.message);
    }

    final userId = token['id'] as String;
    await _tokens.save(AuthTokens(
        accessToken: token['jwToken'] as String, refreshToken: token['refreshToken'] as String, userId: userId));

    final session = await _fetchSession(userId, token);
    final lastUser = await _kv.read(_lastUserKey);
    await _kv.write(_sessionKey(userId), jsonEncode(session.toJson()));
    await _kv.write(_verifierKey(trimmed), jsonEncode(PasswordVerifier.create(userId, password).toJson()));
    await _kv.write(_lastUserKey, userId);
    await _kv.write(_activeKey, userId);
    return LoginResult(session, offline: false, userChanged: lastUser != null && lastUser != userId);
  }

  Future<LoginResult> _offlineLogin(String email, String password) async {
    final raw = await _kv.read(_verifierKey(email));
    if (raw == null) {
      throw AuthFailure("Can't reach the ZARI server, and this account hasn't signed in on this device before. "
          'Connect once to sign in online.');
    }
    final verifier = PasswordVerifier.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (!verifier.verify(password)) throw AuthFailure('Invalid email or password.');
    final session = await cachedSession(verifier.userId);
    if (session == null) throw AuthFailure('No saved profile for this account on this device. Connect to sign in.');
    final lastUser = await _kv.read(_lastUserKey);
    // Tokens belonging to someone else must never be used for this user's sync.
    if (_tokens.current != null && _tokens.current!.userId != verifier.userId) await _tokens.clear();
    await _kv.write(_lastUserKey, verifier.userId);
    await _kv.write(_activeKey, verifier.userId);
    return LoginResult(session, offline: true, userChanged: lastUser != null && lastUser != verifier.userId);
  }

  Future<UserSession> _fetchSession(String userId, Map<String, dynamic> token) async {
    final profile = await _api.get<Map<String, dynamic>>('/api/users/$userId');
    final perms = (await _api.get<List<dynamic>>('/api/users/$userId/permissions')).cast<Map<String, dynamic>>();
    return UserSession(
      userId: userId,
      email: (profile['email'] ?? token['email']) as String,
      firstName: (profile['firstName'] ?? token['firstName'] ?? '') as String,
      lastName: (profile['lastName'] ?? token['lastName'] ?? '') as String,
      roles: ((profile['roleNames'] ?? token['roles'] ?? const []) as List).cast<String>(),
      branchIds: ((profile['branchIds'] ?? const []) as List).cast<String>(),
      permissions: {for (final p in perms.map(FormPermission.fromJson)) p.formCode: p},
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  /// Re-reads profile + permissions while online, so an admin's change in
  /// ZARI web reaches the device without a sign-out.
  Future<UserSession?> refreshSession(UserSession current) async {
    try {
      final fresh = await _fetchSession(current.userId, const {});
      await _kv.write(_sessionKey(current.userId), jsonEncode(fresh.toJson()));
      return fresh;
    } on ApiException {
      return null;
    }
  }

  Future<UserSession?> cachedSession(String userId) async {
    final raw = await _kv.read(_sessionKey(userId));
    return raw == null ? null : UserSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// App start: resume the signed-in user without asking for a password,
  /// like the web app's localStorage session.
  Future<UserSession?> restore() async {
    await _tokens.load();
    final active = await _kv.read(_activeKey);
    if (active == null) return null;
    return cachedSession(active);
  }

  /// Ends the session on this device. The cached profile and offline verifier
  /// stay, so the same user can still unlock offline; queued documents stay
  /// in the outbox until that user signs in again and they sync.
  Future<void> logout() async {
    await _tokens.clear();
    await _kv.delete(_activeKey);
  }
}
