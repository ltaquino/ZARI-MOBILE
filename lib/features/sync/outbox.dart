import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_database.dart';

/// Lifecycle of a document captured on the device:
///
///   pending ──▶ syncing ──▶ synced
///      ▲           │
///      │           ├──▶ pending       request never left the device (offline)
///      │           ├──▶ failed        ZARI rejected it (validation, permission, …)
///      │           └──▶ needsReview   sent, but no answer came back
///      └── retry ── failed / needsReview
///
/// `needsReview` exists because ZARI's create endpoints have no idempotency
/// key: re-sending a POS sale the server already committed would book it
/// twice. A human checks ZARI first, then either retries or marks it done.
enum OutboxStatus { pending, syncing, synced, failed, needsReview }

OutboxStatus _parseStatus(String raw) => switch (raw) {
      'syncing' => OutboxStatus.syncing,
      'synced' => OutboxStatus.synced,
      'failed' => OutboxStatus.failed,
      'needs_review' => OutboxStatus.needsReview,
      _ => OutboxStatus.pending,
    };

String _statusCode(OutboxStatus s) => switch (s) {
      OutboxStatus.pending => 'pending',
      OutboxStatus.syncing => 'syncing',
      OutboxStatus.synced => 'synced',
      OutboxStatus.failed => 'failed',
      OutboxStatus.needsReview => 'needs_review',
    };

abstract final class OutboxType {
  static const posSale = 'pos_sale';
  static const salesOrder = 'sales_order';
  static const stockOpname = 'stock_opname';
  static const stockAdjustment = 'stock_adjustment';

  // Route Sales (truck handheld) — every one of these endpoints is idempotent on the server.
  static const routeSale = 'route_sale';
  static const routeVoid = 'route_void';
  static const routeRefusal = 'route_refusal';
  static const routeReturn = 'route_return';
  static const routeCollection = 'route_collection';
  static const routePod = 'route_pod';
  static const routeEnd = 'route_end';

  static bool isRoute(String type) => type.startsWith('route_');

  static String label(String type) => switch (type) {
        posSale => 'POS sale',
        salesOrder => 'Sales order',
        stockOpname => 'Stock count',
        stockAdjustment => 'Stock adjustment',
        routeSale => 'Route invoice',
        routeVoid => 'Voided invoice no.',
        routeRefusal => 'Not delivered',
        routeReturn => 'Customer return',
        routeCollection => 'Collection',
        routePod => 'Proof of delivery',
        routeEnd => 'End of trip',
        _ => type,
      };
}

class OutboxEntry {
  OutboxEntry({
    required this.id,
    required this.userId,
    required this.branchId,
    required this.type,
    required this.title,
    required this.method,
    required this.path,
    required this.body,
    this.followUpPath,
    this.followUpBody,
    this.meta = const {},
    required this.status,
    this.idempotent = false,
    this.attempts = 0,
    this.lastError,
    this.serverId,
    this.serverRef,
    this.serverResponse,
    required this.createdAt,
    required this.updatedAt,
    this.syncedAt,
  });

  final String id;
  final String userId;
  final String branchId;
  final String type;
  final String title;
  final String method;
  final String path;
  final Map<String, dynamic> body;

  /// Optional second call made once the document exists server-side, e.g.
  /// `/api/sales-orders/{id}/submit`. `{id}` is replaced with [serverId].
  final String? followUpPath;
  final Map<String, dynamic>? followUpBody;

  /// Local-only display data (totals, item names, customer name) — never
  /// sent to ZARI, so request bodies stay exactly the API contract.
  final Map<String, dynamic> meta;

  final OutboxStatus status;

  /// The endpoint is safe to call again with the same body (keyed server-side), so a send whose answer was lost
  /// is simply retried instead of waiting for a human to check ZARI.
  final bool idempotent;
  final int attempts;
  final String? lastError;

  /// Set as soon as the create call succeeds — so a retry after a failed
  /// follow-up only re-runs the follow-up, never the create.
  final String? serverId;

  /// The ZARI document number (invoice no., SO no., …) once known.
  final String? serverRef;
  final Map<String, dynamic>? serverResponse;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? syncedAt;

  /// Short human reference, also stamped into the document's remarks so the
  /// record can be found in ZARI web when reconciling a `needsReview` entry.
  String get localRef => mobileRef(id);

  bool get isOpen => status != OutboxStatus.synced;

  factory OutboxEntry.fromRow(Map<String, Object?> r) => OutboxEntry(
        id: r['id'] as String,
        userId: r['user_id'] as String,
        branchId: r['branch_id'] as String,
        type: r['type'] as String,
        title: r['title'] as String,
        method: r['method'] as String,
        path: r['path'] as String,
        body: jsonDecode(r['body'] as String) as Map<String, dynamic>,
        followUpPath: r['follow_up_path'] as String?,
        followUpBody: r['follow_up_body'] == null ? null : jsonDecode(r['follow_up_body'] as String) as Map<String, dynamic>,
        meta: r['meta'] == null ? const {} : jsonDecode(r['meta'] as String) as Map<String, dynamic>,
        status: _parseStatus(r['status'] as String),
        idempotent: (r['idempotent'] as int? ?? 0) == 1,
        attempts: r['attempts'] as int,
        lastError: r['last_error'] as String?,
        serverId: r['server_id'] as String?,
        serverRef: r['server_ref'] as String?,
        serverResponse:
            r['server_response'] == null ? null : jsonDecode(r['server_response'] as String) as Map<String, dynamic>,
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
        syncedAt: r['synced_at'] == null ? null : DateTime.parse(r['synced_at'] as String),
      );
}

String mobileRef(String id) => 'MOB-${id.replaceAll('-', '').substring(0, 8).toUpperCase()}';

/// ZARI caps remarks at 300 chars; the mobile reference tag must always fit.
String stampRemarks(String localRef, String? remarks) {
  final tag = '[$localRef]';
  final user = (remarks ?? '').trim();
  final room = 300 - tag.length - 1;
  return user.isEmpty ? tag : '$tag ${user.length > room ? user.substring(0, room) : user}';
}

class OutboxRepository {
  OutboxRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Pre-allocates an id so callers can stamp [mobileRef] into the payload
  /// (e.g. the remarks field) before enqueueing.
  String newId() => _uuid.v4();

  Future<OutboxEntry> enqueue({
    String? id,
    required String userId,
    required String branchId,
    required String type,
    required String title,
    required String path,
    required Map<String, dynamic> body,
    String method = 'POST',
    String? followUpPath,
    Map<String, dynamic>? followUpBody,
    Map<String, dynamic>? meta,
    bool idempotent = false,
    DatabaseExecutor? txn,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final entryId = id ?? newId();
    await (txn ?? _db.db).insert('outbox', {
      'id': entryId,
      'user_id': userId,
      'branch_id': branchId,
      'type': type,
      'title': title,
      'method': method,
      'path': path,
      'body': jsonEncode(body),
      'follow_up_path': followUpPath,
      'follow_up_body': followUpBody == null ? null : jsonEncode(followUpBody),
      'meta': meta == null ? null : jsonEncode(meta),
      'status': 'pending',
      'idempotent': idempotent ? 1 : 0,
      'attempts': 0,
      'created_at': now,
      'updated_at': now,
    });
    if (txn != null) return OutboxEntry.fromRow((await txn.query('outbox', where: 'id = ?', whereArgs: [entryId])).first);
    return (await get(entryId))!;
  }

  Future<OutboxEntry?> get(String id) async {
    final rows = await _db.db.query('outbox', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : OutboxEntry.fromRow(rows.first);
  }

  Future<List<OutboxEntry>> list({Set<OutboxStatus>? statuses, String? userId, String? type, int? limit}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (statuses != null && statuses.isNotEmpty) {
      where.add('status IN (${List.filled(statuses.length, '?').join(',')})');
      args.addAll(statuses.map(_statusCode));
    }
    if (userId != null) {
      where.add('user_id = ?');
      args.add(userId);
    }
    if (type != null) {
      where.add('type = ?');
      args.add(type);
    }
    final rows = await _db.db.query('outbox',
        where: where.isEmpty ? null : where.join(' AND '), whereArgs: args, orderBy: 'created_at ASC, rowid ASC', limit: limit);
    return rows.map(OutboxEntry.fromRow).toList();
  }

  Future<Map<OutboxStatus, int>> counts({String? userId}) async {
    final rows = await _db.db.rawQuery(
        'SELECT status, COUNT(*) AS c FROM outbox ${userId == null ? '' : 'WHERE user_id = ?'} GROUP BY status',
        userId == null ? [] : [userId]);
    return {for (final r in rows) _parseStatus(r['status'] as String): r['c'] as int};
  }

  Future<void> _update(String id, Map<String, Object?> values) =>
      _db.db.update('outbox', {...values, 'updated_at': DateTime.now().toUtc().toIso8601String()},
          where: 'id = ?', whereArgs: [id]);

  Future<void> markSyncing(String id) =>
      _db.db.rawUpdate("UPDATE outbox SET status = 'syncing', attempts = attempts + 1, updated_at = ? WHERE id = ?",
          [DateTime.now().toUtc().toIso8601String(), id]);

  Future<void> markCreated(String id, {required String serverId, String? serverRef, Map<String, dynamic>? response}) =>
      _update(id, {
        'server_id': serverId,
        'server_ref': serverRef,
        if (response != null) 'server_response': jsonEncode(response),
      });

  Future<void> markSynced(String id) =>
      _update(id, {'status': 'synced', 'last_error': null, 'synced_at': DateTime.now().toUtc().toIso8601String()});

  Future<void> markPending(String id, {String? error}) => _update(id, {'status': 'pending', 'last_error': error});

  Future<void> markFailed(String id, String error) => _update(id, {'status': 'failed', 'last_error': error});

  Future<void> markNeedsReview(String id, String error) => _update(id, {'status': 'needs_review', 'last_error': error});

  /// After a human confirmed in ZARI web that the document does exist.
  Future<void> resolveManually(String id, {String? serverRef}) => _update(id, {
        'status': 'synced',
        'last_error': 'Marked as synced manually after review.',
        if (serverRef != null && serverRef.isNotEmpty) 'server_ref': serverRef,
        'synced_at': DateTime.now().toUtc().toIso8601String(),
      });

  Future<void> discard(String id) => _db.db.delete('outbox', where: "id = ? AND status != 'synced'", whereArgs: [id]);

  /// A row left in `syncing` means the app died mid-request — we can't know
  /// whether ZARI got the create, so it goes to review rather than back to
  /// pending. If the create had already succeeded (server id recorded) only
  /// the follow-up step remains, and re-running that is harmless.
  Future<void> recoverInterrupted() async {
    await _db.db.rawUpdate(
        "UPDATE outbox SET status = 'pending' WHERE status = 'syncing' AND (server_id IS NOT NULL OR idempotent = 1)");
    await _db.db.rawUpdate(
        "UPDATE outbox SET status = 'needs_review', last_error = ? WHERE status = 'syncing'",
        ['The app closed while this was being sent. Check ZARI before retrying.']);
  }

  /// Housekeeping: synced rows older than [keep] are only history.
  Future<int> pruneSynced({Duration keep = const Duration(days: 30)}) => _db.db.delete('outbox',
      where: "status = 'synced' AND synced_at < ?", whereArgs: [DateTime.now().toUtc().subtract(keep).toIso8601String()]);
}
