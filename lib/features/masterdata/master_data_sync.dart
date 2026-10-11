import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/app_database.dart';
import 'models.dart';

typedef PullProgress = void Function(String stage, double? fraction);

class PullResult {
  final Map<String, int> counts = {};

  /// Entities this user isn't allowed to read (403) — skipped, not fatal.
  final Map<String, String> skipped = {};
}

/// Downloads ZARI master data into the local cache.
///
/// A *full* pull (`includeItems`, the daily catalog refresh or on demand) re-downloads everything and prunes what's
/// gone from ZARI; the item catalog is paged so a 100k-SKU catalog never sits in memory at once. A *quick* pull (after
/// every push, every 15 min) asks only for prices, stock, customers and items changed since the last pull
/// (`updatedSince`) and upserts them — ZARI doesn't report deletions, which the next full pull prunes. Prices and stock
/// are requested per branch (`branchId`). The "since" cursor is ZARI's own clock (the response's `Date` header) less
/// [cursorOverlap], so neither the device's clock nor a transaction committing a moment late can skip a change.
class MasterDataSync {
  MasterDataSync(this._api, this._db);

  final ApiClient _api;
  final AppDatabase _db;

  static const itemPageSize = 500;
  static const metaItems = 'pull.items';
  static const metaStock = 'pull.stock';
  static const metaRef = 'pull.ref';
  static const cursorPrices = 'cursor.prices';
  static const cursorStock = 'cursor.stock';
  static const cursorCustomers = 'cursor.customers';
  static const cursorItems = 'cursor.items';
  static const cursorOverlap = Duration(minutes: 2);

  static final _refSources = <String, String>{
    RefEntity.branch: '/api/branches',
    RefEntity.warehouse: '/api/warehouses',
    RefEntity.uom: '/api/uoms',
    RefEntity.customer: '/api/customers',
    RefEntity.paymentMethod: '/api/payment-methods',
    RefEntity.posTerminal: '/api/pos-terminals',
    RefEntity.statutoryDiscountType: '/api/statutory-discount-types',
    RefEntity.adjustmentReason: '/api/adjustment-reasons',
  };

  Future<DateTime?> lastPulled(String metaKey) async {
    final raw = await _db.getMeta(metaKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// [includeItems] = false is the "quick" refresh run after every push:
  /// prices, stock and reference lists only, skipping the (large) catalog.
  Future<PullResult> pull({required Set<String> branchIds, bool includeItems = true, PullProgress? onProgress}) async {
    final result = PullResult();
    final full = includeItems;

    var step = 0;
    for (final entry in _refSources.entries) {
      onProgress?.call('Downloading ${entry.key.replaceAll('_', ' ')}s', step++ / _refSources.length);
      await _guard(result, entry.key, () async {
        if (entry.key == RefEntity.customer) {
          // Customers can run into the thousands — a quick pull only fetches the ones changed since.
          final since = full ? null : await _cursor(cursorCustomers);
          final (raw, serverTime) =
              await _api.getWithServerTime<List<dynamic>>(entry.value, query: {if (since != null) 'updatedSince': since});
          final list = raw.cast<Map<String, dynamic>>();
          await _writeRef(entry.key, list, replace: since == null);
          await _setCursor(cursorCustomers, serverTime);
          result.counts[entry.key] = list.length;
          return;
        }
        final list = (await _api.get<List<dynamic>>(entry.value)).cast<Map<String, dynamic>>();
        await _writeRef(entry.key, list, replace: true);
        result.counts[entry.key] = list.length;
      });
    }
    await _guard(result, RefEntity.company, () async {
      final company = await _api.get<Map<String, dynamic>>('/api/company');
      await _writeRef(RefEntity.company, replace: true, [
        {...company, 'id': company['id'] ?? 'company'}
      ]);
      result.counts[RefEntity.company] = 1;
    });
    // A cashier/encoder/driver can't read the admin screens behind /api/company and /api/branches; the read-only
    // /api/device-settings carries what the app needs from them (discount threshold, the user's branch names).
    if (result.skipped.containsKey(RefEntity.company) || result.skipped.containsKey(RefEntity.branch)) {
      await _guard(result, 'device_settings', () async {
        final settings = await _api.get<Map<String, dynamic>>('/api/device-settings');
        if (result.skipped.remove(RefEntity.company) != null) {
          await _writeRef(RefEntity.company, replace: true, [
            {
              'id': 'company',
              'name': settings['companyName'],
              'tradeName': settings['tradeName'],
              'maxUnapprovedDiscountPct': settings['maxUnapprovedDiscountPct'],
            }
          ]);
          result.counts[RefEntity.company] = 1;
        }
        if (result.skipped.remove(RefEntity.branch) != null) {
          final branches = (settings['branches'] as List? ?? const []).cast<Map<String, dynamic>>();
          await _writeRef(RefEntity.branch, branches, replace: true);
          result.counts[RefEntity.branch] = branches.length;
        }
      });
    }
    await _db.setMeta(metaRef, DateTime.now().toUtc().toIso8601String());

    onProgress?.call('Downloading prices', null);
    await _guard(result, 'item_branch_settings', () async {
      final rows = await _pullBranchScoped('/api/item-branch-settings', cursorPrices, branchIds, full: full,
          toRow: (j) {
            final s = ItemBranchSetting.fromApi(j);
            return branchIds.contains(s.branchId) ? s.toRow() : null;
          },
          table: 'item_branch_settings');
      result.counts['item_branch_settings'] = rows;
    });

    onProgress?.call('Downloading stock balances', null);
    await _guard(result, 'stock_balances', () async {
      final rows = await _pullBranchScoped('/api/stock-ledger/balances', cursorStock, branchIds, full: full,
          toRow: (j) {
            final b = StockBalance.fromApi(j);
            return branchIds.contains(b.branchId) ? b.toRow() : null;
          },
          table: 'stock_balances');
      result.counts['stock_balances'] = rows;
      await _db.setMeta(metaStock, DateTime.now().toUtc().toIso8601String());
    });

    if (includeItems) {
      await _guard(result, 'items', () async {
        result.counts['items'] = await _pullItems(onProgress);
        await _db.setMeta(metaItems, DateTime.now().toUtc().toIso8601String());
      });
    } else {
      // Quick pull: items created or edited in ZARI since the last pull (a new product, a renamed one), upserted.
      final since = await _cursor(cursorItems);
      if (since != null) {
        await _guard(result, 'items', () async {
          result.counts['items'] = await _pullItems(onProgress, updatedSince: since);
        });
      }
    }

    onProgress?.call('Done', 1);
    return result;
  }

  /// Prices or stock for each of the user's branches: a full refresh replaces the table (dropping rows ZARI no longer
  /// has), a quick one upserts only what changed since the cursor. The cursor moves only once every branch is in.
  Future<int> _pullBranchScoped(String path, String cursorKey, Set<String> branchIds,
      {required bool full, required Map<String, Object?>? Function(Map<String, dynamic>) toRow, required String table}) async {
    final since = full ? null : await _cursor(cursorKey);
    final rows = <Map<String, Object?>>[];
    DateTime? serverTime;
    for (final branchId in branchIds) {
      final (raw, time) = await _api.getWithServerTime<List<dynamic>>(path,
          query: {'branchId': branchId, if (since != null) 'updatedSince': since});
      serverTime ??= time;
      rows.addAll(raw.cast<Map<String, dynamic>>().map(toRow).whereType<Map<String, Object?>>());
    }
    if (since == null) {
      await _replaceTable(table, rows);
    } else {
      final batch = _db.db.batch();
      for (final row in rows) {
        batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }
    await _setCursor(cursorKey, serverTime);
    return rows.length;
  }

  /// The "changed since" value for a quick pull, or null when there's no cursor yet (→ full download).
  Future<String?> _cursor(String key) => _db.getMeta(key);

  Future<void> _setCursor(String key, DateTime? serverTime) async {
    if (serverTime == null) return; // no server clock — the next quick pull downloads everything again
    await _db.setMeta(key, serverTime.toUtc().subtract(cursorOverlap).toIso8601String());
  }

  Future<int> _pullItems(PullProgress? onProgress, {String? updatedSince}) async {
    final seen = <String>{};
    var page = 1;
    var total = 0;
    DateTime? serverTime;
    while (true) {
      final (res, time) = await _api.getWithServerTime<Map<String, dynamic>>('/api/items/paged',
          query: {'page': page, 'pageSize': itemPageSize, if (updatedSince != null) 'updatedSince': updatedSince});
      serverTime ??= time;
      final items = (res['items'] as List).cast<Map<String, dynamic>>().map(Item.fromApi).toList();
      total = (res['totalCount'] as num?)?.toInt() ?? total;
      final batch = _db.db.batch();
      for (final item in items) {
        batch.insert('items', item.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
        seen.add(item.id);
      }
      await batch.commit(noResult: true);
      onProgress?.call('Downloading items (${seen.length}${total > 0 ? ' of $total' : ''})', total > 0 ? seen.length / total : null);
      if (items.length < itemPageSize) break;
      page++;
    }
    await _setCursor(cursorItems, serverTime);
    if (updatedSince != null) return seen.length; // a delta can't tell what was deleted — the next full pull prunes

    // Upsert-then-prune instead of delete-then-insert, so an interrupted
    // download never leaves the device with a half-empty catalog.
    final localIds = (await _db.db.query('items', columns: ['id'])).map((r) => r['id'] as String);
    final stale = localIds.where((id) => !seen.contains(id)).toList();
    for (var i = 0; i < stale.length; i += 500) {
      final chunk = stale.sublist(i, i + 500 > stale.length ? stale.length : i + 500);
      await _db.db.delete('items', where: 'id IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
    }
    return seen.length;
  }

  Future<void> _guard(PullResult result, String entity, Future<void> Function() body) async {
    try {
      await body();
    } on ApiException catch (e) {
      if (e.kind == ApiFailureKind.forbidden || e.kind == ApiFailureKind.notFound) {
        result.skipped[entity] = e.message;
        return;
      }
      rethrow;
    }
  }

  Future<void> _replaceTable(String table, Iterable<Map<String, Object?>> rows) async {
    await _db.db.transaction((txn) async {
      await txn.delete(table);
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> _writeRef(String entity, List<Map<String, dynamic>> list, {required bool replace}) async {
    await _db.db.transaction((txn) async {
      if (replace) await txn.delete('ref_data', where: 'entity = ?', whereArgs: [entity]);
      final batch = txn.batch();
      for (final json in list) {
        final rec = RefRecord(entity, json);
        batch.insert(
            'ref_data',
            {
              'entity': entity,
              'id': rec.id,
              // Customers are looked up at the counter by member no. or phone.
              'code': entity == RefEntity.customer ? (json['memberNo'] ?? json['phone']) as String? : rec.code,
              'name': rec.name,
              'branch_id': rec.branchId,
              'status': rec.status,
              'json': jsonEncode(json),
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }
}
