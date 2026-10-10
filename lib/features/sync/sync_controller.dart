import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/providers.dart';
import '../auth/auth_controller.dart';
import '../auth/session.dart';
import '../masterdata/master_data_sync.dart';
import 'outbox.dart';
import 'outbox_processor.dart';

enum PullMode {
  /// Full catalog only when it's missing or older than a day; otherwise a
  /// quick price/stock refresh when something was just pushed.
  auto,
  quick,
  full,
  none,
}

class SyncState {
  const SyncState({
    this.online = true,
    this.pushing = false,
    this.pulling = false,
    this.pullStage,
    this.pullFraction,
    this.counts = const {},
    this.lastItemsPull,
    this.lastStockPull,
    this.lastPushAt,
    this.lastTripsPull,
    this.message,
    this.skipped = const {},
  });

  final bool online;
  final bool pushing;
  final bool pulling;
  final String? pullStage;
  final double? pullFraction;
  final Map<OutboxStatus, int> counts;
  final DateTime? lastItemsPull;
  final DateTime? lastStockPull;
  final DateTime? lastPushAt;

  /// Route Sales: when the driver's trips were last downloaded (screens watch it to refresh).
  final DateTime? lastTripsPull;
  final String? message;
  final Map<String, String> skipped;

  bool get busy => pushing || pulling;
  int get pendingCount => (counts[OutboxStatus.pending] ?? 0) + (counts[OutboxStatus.syncing] ?? 0);
  int get attentionCount => (counts[OutboxStatus.failed] ?? 0) + (counts[OutboxStatus.needsReview] ?? 0);
  bool get hasCatalog => lastItemsPull != null;

  SyncState copyWith({
    bool? online,
    bool? pushing,
    bool? pulling,
    String? pullStage,
    double? pullFraction,
    Map<OutboxStatus, int>? counts,
    DateTime? lastItemsPull,
    DateTime? lastStockPull,
    DateTime? lastPushAt,
    DateTime? lastTripsPull,
    String? message,
    Map<String, String>? skipped,
    bool clearMessage = false,
    bool clearPullProgress = false,
  }) =>
      SyncState(
        online: online ?? this.online,
        pushing: pushing ?? this.pushing,
        pulling: pulling ?? this.pulling,
        pullStage: clearPullProgress ? null : (pullStage ?? this.pullStage),
        pullFraction: clearPullProgress ? null : (pullFraction ?? this.pullFraction),
        counts: counts ?? this.counts,
        lastItemsPull: lastItemsPull ?? this.lastItemsPull,
        lastStockPull: lastStockPull ?? this.lastStockPull,
        lastPushAt: lastPushAt ?? this.lastPushAt,
        lastTripsPull: lastTripsPull ?? this.lastTripsPull,
        message: clearMessage ? null : (message ?? this.message),
        skipped: skipped ?? this.skipped,
      );
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(SyncController.new);

/// Orchestrates both directions: push the outbox, then pull fresh master
/// data. Runs on sign-in, when connectivity returns, every few minutes while
/// the app is open, right after a document is queued, and on demand.
class SyncController extends Notifier<SyncState> {
  static const _interval = Duration(minutes: 3);
  static const _catalogMaxAge = Duration(hours: 24);
  static const _stockMaxAge = Duration(minutes: 15);

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Future<void>? _running;
  bool _started = false;

  @override
  SyncState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _connSub?.cancel();
    });
    return const SyncState();
  }

  /// Idempotent; called once a user is signed in.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await ref.read(outboxRepositoryProvider).recoverInterrupted();
    await ref.read(outboxRepositoryProvider).pruneSynced();
    await refreshLocal();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        unawaited(syncNow());
      } else {
        state = state.copyWith(online: false);
      }
    });
    _timer = Timer.periodic(_interval, (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  void stop() {
    _timer?.cancel();
    _connSub?.cancel();
    _timer = null;
    _connSub = null;
    _started = false;
    state = const SyncState();
  }

  /// Re-reads queue counts and pull timestamps from the local DB.
  Future<void> refreshLocal() async {
    final userId = ref.read(authControllerProvider).session?.userId;
    final sync = ref.read(masterDataSyncProvider);
    state = state.copyWith(
      counts: await ref.read(outboxRepositoryProvider).counts(userId: userId),
      lastItemsPull: await sync.lastPulled(MasterDataSync.metaItems),
      lastStockPull: await sync.lastPulled(MasterDataSync.metaStock),
    );
  }

  /// Call right after queueing a document: push it now if we can.
  Future<void> kick() async {
    await refreshLocal();
    unawaited(syncNow());
  }

  Future<void> syncNow({PullMode pull = PullMode.auto}) {
    // Collapse overlapping triggers onto the run already in flight.
    return _running ??= _guarded(pull).whenComplete(() => _running = null);
  }

  Future<void> _guarded(PullMode pull) async {
    try {
      await _run(pull);
    } catch (e) {
      // Never let a background sync crash the app; surface it instead.
      state = state.copyWith(pushing: false, pulling: false, clearPullProgress: true, message: 'Sync error: $e');
    }
  }

  /// Re-sends one failed / needs-review entry after the user chose to.
  Future<void> retry(OutboxEntry entry) async {
    await ref.read(outboxRepositoryProvider).markPending(entry.id, error: entry.lastError);
    await kick();
  }

  Future<void> _run(PullMode pull) async {
    final auth = ref.read(authControllerProvider.notifier);
    final session = ref.read(authControllerProvider).session;
    if (session == null) return;

    final api = ref.read(apiClientProvider);
    final online = await api.ping();
    state = state.copyWith(online: online, clearMessage: true);
    if (!online) return;

    if (!await auth.ensureOnlineSession()) {
      state = state.copyWith(message: 'Sign in again to sync your saved work.');
      await refreshLocal();
      return;
    }

    // 1) Push.
    final PushReport report;
    state = state.copyWith(pushing: true);
    try {
      report = await ref.read(outboxProcessorProvider).pushAll(userId: session.userId);
      state = state.copyWith(lastPushAt: DateTime.now());
      if (report.stoppedBy == PushStop.offline) state = state.copyWith(online: false, message: report.stopMessage);
      if (report.stoppedBy == PushStop.unauthorized) state = state.copyWith(message: report.stopMessage);
    } finally {
      state = state.copyWith(pushing: false);
      await refreshLocal();
    }
    if (report.stoppedBy != PushStop.none) return;

    // 1b) Route Sales: the driver's trips (status, newest series number, open invoices). Never fatal.
    if (session.can(Forms.routeSales, FormAction.create)) {
      try {
        await ref.read(routeServiceProvider).download(session.userId);
        state = state.copyWith(lastTripsPull: DateTime.now());
      } on ApiException catch (_) {
        // Offline mid-way or no trips endpoint access — the cached trips keep working.
      }
    }

    // 2) Pull.
    final mode = _resolvePull(pull, pushedSomething: report.synced > 0);
    if (mode != PullMode.none) await _pull(full: mode == PullMode.full, branchIds: session.branchIds.toSet());
    if (mode == PullMode.full) await auth.refreshProfile();
  }

  PullMode _resolvePull(PullMode requested, {required bool pushedSomething}) {
    if (requested != PullMode.auto) return requested;
    final now = DateTime.now();
    if (state.lastItemsPull == null || now.difference(state.lastItemsPull!) > _catalogMaxAge) return PullMode.full;
    if (pushedSomething || state.lastStockPull == null || now.difference(state.lastStockPull!) > _stockMaxAge) {
      return PullMode.quick;
    }
    return PullMode.none;
  }

  Future<void> _pull({required bool full, required Set<String> branchIds}) async {
    state = state.copyWith(pulling: true, pullStage: 'Starting download', pullFraction: 0);
    try {
      final result = await ref.read(masterDataSyncProvider).pull(
            branchIds: branchIds,
            includeItems: full,
            onProgress: (stage, fraction) => state = state.copyWith(pullStage: stage, pullFraction: fraction),
          );
      state = state.copyWith(skipped: result.skipped);
    } on ApiException catch (e) {
      state = state.copyWith(
          message: 'Download stopped: ${e.message}', online: e.kind == ApiFailureKind.offline ? false : null);
    } finally {
      state = state.copyWith(pulling: false, clearPullProgress: true);
      await refreshLocal();
    }
  }
}
