import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/providers.dart';
import 'auth_repository.dart';
import 'session.dart';

class AuthState {
  const AuthState({
    this.session,
    this.restoring = true,
    this.offlineSession = false,
    this.needsReauth = false,
    this.branchId,
  });

  final UserSession? session;
  final bool restoring;

  /// Unlocked with the cached verifier; no fresh token from ZARI yet.
  final bool offlineSession;

  /// The refresh token was rejected — the user must type their password
  /// again before the outbox can sync. Their queued work is untouched.
  final bool needsReauth;

  /// The branch every screen works in — always one of session.branchIds.
  final String? branchId;

  bool get isSignedIn => session != null;

  AuthState copyWith({
    UserSession? session,
    bool? restoring,
    bool? offlineSession,
    bool? needsReauth,
    String? branchId,
    bool clearSession = false,
  }) =>
      AuthState(
        session: clearSession ? null : (session ?? this.session),
        restoring: restoring ?? this.restoring,
        offlineSession: offlineSession ?? this.offlineSession,
        needsReauth: needsReauth ?? this.needsReauth,
        branchId: clearSession ? null : (branchId ?? this.branchId),
      );
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

class AuthController extends Notifier<AuthState> {
  /// Kept in memory only (never persisted) during an offline-unlocked session
  /// so the app can silently get a real token the moment ZARI is reachable.
  String? _pendingPassword;

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  @override
  AuthState build() {
    ref.read(apiClientProvider).onSessionExpired = () {
      if (state.isSignedIn) state = state.copyWith(needsReauth: true);
    };
    return const AuthState();
  }

  Future<void> restore() async {
    final session = await _repo.restore();
    if (session == null) {
      state = const AuthState(restoring: false);
      return;
    }
    state = AuthState(
      session: session,
      restoring: false,
      needsReauth: !_repo.hasTokens,
      branchId: await _initialBranch(session),
    );
  }

  Future<void> login(String email, String password) async {
    final LoginResult result;
    try {
      result = await _repo.login(email, password);
    } on ApiException catch (e) {
      // Signed in but the profile fetch then failed — don't leave half a session.
      await _repo.logout();
      throw AuthFailure(e.message);
    }
    // Different user on a shared device: drop the previous user's branch-scoped
    // cache — but only when online, where it's re-downloaded straight away.
    // Offline, a stale cache beats an empty one (screens filter by branch).
    if (result.userChanged && !result.offline) await ref.read(databaseProvider).clearCache();
    _pendingPassword = result.offline ? password : null;
    state = AuthState(
      session: result.session,
      restoring: false,
      offlineSession: result.offline,
      needsReauth: false,
      branchId: await _initialBranch(result.session),
    );
  }

  /// Called by the sync engine once ZARI is reachable again. Returns true
  /// when the user now has a valid token.
  Future<bool> ensureOnlineSession() async {
    if (!state.isSignedIn) return false;
    if (_repo.hasTokens && !state.needsReauth) {
      if (state.offlineSession) state = state.copyWith(offlineSession: false);
      return true;
    }
    final pw = _pendingPassword;
    if (pw == null) {
      state = state.copyWith(needsReauth: true);
      return false;
    }
    try {
      await reauthenticate(pw);
      return true;
    } on AuthFailure {
      state = state.copyWith(needsReauth: true);
      return false;
    }
  }

  /// Online sign-in again for the current user (expired session banner).
  Future<void> reauthenticate(String password) async {
    final session = state.session;
    if (session == null) return;
    final result = await _repo.login(session.email, password);
    if (result.offline) throw AuthFailure('Still offline — try again once connected.');
    _pendingPassword = null;
    state = state.copyWith(session: result.session, offlineSession: false, needsReauth: false);
  }

  Future<void> refreshProfile() async {
    final session = state.session;
    if (session == null || state.offlineSession) return;
    final fresh = await _repo.refreshSession(session);
    if (fresh != null) state = state.copyWith(session: fresh);
  }

  Future<void> setBranch(String branchId) async {
    final session = state.session;
    if (session == null || !session.branchIds.contains(branchId)) return;
    await ref.read(keyValueStoreProvider).write(_branchKey(session.userId), branchId);
    state = state.copyWith(branchId: branchId);
  }

  Future<void> logout() async {
    _pendingPassword = null;
    await _repo.logout();
    state = const AuthState(restoring: false);
  }

  static String _branchKey(String userId) => 'zari.branch.$userId';

  Future<String?> _initialBranch(UserSession session) async {
    final saved = await ref.read(keyValueStoreProvider).read(_branchKey(session.userId));
    if (saved != null && session.branchIds.contains(saved)) return saved;
    return session.branchIds.isEmpty ? null : session.branchIds.first;
  }
}
