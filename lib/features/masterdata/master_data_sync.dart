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

/// Downloads ZARI master data into the local cache. ZARI's list endpoints
/// have no "changed since" filter, so every entity is a full refresh; the
/// item catalog is paged so a 100k-SKU catalog never sits in memory at once.
class MasterDataSync {
  MasterDataSync(this._api, this._db);

  final ApiClient _api;
  final AppDatabase _db;

  static const itemPageSize = 500;
  static const metaItems = 'pull.items';
  static const metaStock = 'pull.stock';
  static const metaRef = 'pull.ref';

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

    var step = 0;
    for (final entry in _refSources.entries) {
      onProgress?.call('Downloading ${entry.key.replaceAll('_', ' ')}s', step++ / _refSources.length);
      await _guard(result, entry.key, () async {
        final list = (await _api.get<List<dynamic>>(entry.value)).cast<Map<String, dynamic>>();
        await _replaceRef(entry.key, list);
        result.counts[entry.key] = list.length;
      });
    }
    await _guard(result, RefEntity.company, () async {
      final company = await _api.get<Map<String, dynamic>>('/api/company');
      await _replaceRef(RefEntity.company, [
        {...company, 'id': company['id'] ?? 'company'}
      ]);
      result.counts[RefEntity.company] = 1;
    });
    await _db.setMeta(metaRef, DateTime.now().toUtc().toIso8601String());

    onProgress?.call('Downloading prices', null);
    await _guard(result, 'item_branch_settings', () async {
      final list = (await _api.get<List<dynamic>>('/api/item-branch-settings'))
          .cast<Map<String, dynamic>>()
          .map(ItemBranchSetting.fromApi)
          .where((s) => branchIds.contains(s.branchId))
          .toList();
      await _replaceTable('item_branch_settings', list.map((s) => s.toRow()));
      result.counts['item_branch_settings'] = list.length;
    });

    onProgress?.call('Downloading stock balances', null);
    await _guard(result, 'stock_balances', () async {
      final list = (await _api.get<List<dynamic>>('/api/stock-ledger/balances'))
          .cast<Map<String, dynamic>>()
          .map(StockBalance.fromApi)
          .where((b) => branchIds.contains(b.branchId))
          .toList();
      await _replaceTable('stock_balances', list.map((b) => b.toRow()));
      result.counts['stock_balances'] = list.length;
      await _db.setMeta(metaStock, DateTime.now().toUtc().toIso8601String());
    });

    if (includeItems) {
      await _guard(result, 'items', () async {
        result.counts['items'] = await _pullItems(onProgress);
        await _db.setMeta(metaItems, DateTime.now().toUtc().toIso8601String());
      });
    }

    onProgress?.call('Done', 1);
    return result;
  }

  Future<int> _pullItems(PullProgress? onProgress) async {
    final seen = <String>{};
    var page = 1;
    var total = 0;
    while (true) {
      final res = await _api.get<Map<String, dynamic>>('/api/items/paged', query: {'page': page, 'pageSize': itemPageSize});
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

  Future<void> _replaceRef(String entity, List<Map<String, dynamic>> list) async {
    await _db.db.transaction((txn) async {
      await txn.delete('ref_data', where: 'entity = ?', whereArgs: [entity]);
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
