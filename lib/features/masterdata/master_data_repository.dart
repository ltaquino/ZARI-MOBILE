import 'dart:convert';

import '../../core/app_database.dart';
import 'models.dart';

/// An item as a list row: identity plus the branch-specific facts every
/// screen wants next to it (POS price, default warehouse, cached on-hand).
class ItemEntry {
  const ItemEntry({required this.item, this.setting, required this.onHand});

  final Item item;
  final ItemBranchSetting? setting;

  /// Branch-wide cached on-hand, summed across warehouses and batches.
  final double onHand;

  double? get price => setting?.sellingPrice;

  /// Mirrors CreatePosSaleCommandHandler: sellable at POS only with an active
  /// branch setting, and a default warehouse when the item is stocked.
  String? get posBlockReason {
    if (!item.isActive) return 'Item is inactive.';
    if (!item.isSold) return 'Item is not flagged as sold.';
    if (setting == null || !setting!.isActive) return 'Item is not set up for sale at this branch.';
    if (item.isStocked && setting!.defaultWarehouseId == null) return 'Item has no default warehouse at this branch.';
    return null;
  }
}

/// Read side of the offline cache. Every query here works with no network.
class MasterDataRepository {
  MasterDataRepository(this._db);

  final AppDatabase _db;

  static const _itemEntrySelect = '''
    SELECT i.*,
           s.id AS s_id, s.default_warehouse_id AS s_default_warehouse_id,
           s.selling_price AS s_selling_price, s.status AS s_status,
           (SELECT COALESCE(SUM(b.qty_on_hand), 0) FROM stock_balances b
             WHERE b.item_id = i.id AND b.branch_id = ?) AS on_hand
      FROM items i
      LEFT JOIN item_branch_settings s ON s.item_id = i.id AND s.branch_id = ?''';

  ItemEntry _entryFromRow(Map<String, Object?> r, String branchId) => ItemEntry(
        item: Item.fromRow(r),
        setting: r['s_id'] == null
            ? null
            : ItemBranchSetting(
                id: r['s_id'] as String,
                itemId: r['id'] as String,
                branchId: branchId,
                defaultWarehouseId: r['s_default_warehouse_id'] as String?,
                sellingPrice: (r['s_selling_price'] as num?)?.toDouble(),
                status: r['s_status'] as String,
              ),
        onHand: (r['on_hand'] as num?)?.toDouble() ?? 0,
      );

  Future<List<ItemEntry>> searchItems(String query, {required String branchId, bool sellableOnly = false, int limit = 50}) async {
    final q = query.trim();
    final where = <String>[];
    final args = <Object?>[branchId, branchId];
    if (q.isNotEmpty) {
      where.add('(i.code LIKE ? OR i.name LIKE ?)');
      args.addAll(['%$q%', '%$q%']);
    }
    if (sellableOnly) where.add("i.is_sold = 1 AND s.id IS NOT NULL AND lower(s.status) = 'active'");
    final sql = '$_itemEntrySelect ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY i.code LIMIT ?';
    args.add(limit);
    final rows = await _db.db.rawQuery(sql, args);
    return rows.map((r) => _entryFromRow(r, branchId)).toList();
  }

  /// Exact code match first — what a barcode scanner or keyboard wedge
  /// "types". ZARI has no barcode master yet, so item codes are the barcode.
  Future<ItemEntry?> findByCode(String code, {required String branchId}) async {
    final rows = await _db.db.rawQuery('$_itemEntrySelect WHERE i.code = ? COLLATE NOCASE LIMIT 1', [branchId, branchId, code.trim()]);
    return rows.isEmpty ? null : _entryFromRow(rows.first, branchId);
  }

  Future<ItemEntry?> itemEntry(String itemId, {required String branchId}) async {
    final rows = await _db.db.rawQuery('$_itemEntrySelect WHERE i.id = ? LIMIT 1', [branchId, branchId, itemId]);
    return rows.isEmpty ? null : _entryFromRow(rows.first, branchId);
  }

  Future<int> itemCount() async =>
      (await _db.db.rawQuery('SELECT COUNT(*) AS c FROM items')).first['c'] as int;

  Future<List<StockBalance>> balancesForItem(String itemId, {String? branchId}) async {
    final rows = await _db.db.query('stock_balances',
        where: branchId == null ? 'item_id = ?' : 'item_id = ? AND branch_id = ?',
        whereArgs: branchId == null ? [itemId] : [itemId, branchId],
        orderBy: 'warehouse_id, batch_no');
    return rows.map(StockBalance.fromRow).toList();
  }

  /// Cached qty and weighted cost for one item at one warehouse, all batches.
  Future<({double qty, double avgCost})> balanceAt(String itemId, String warehouseId) async {
    final rows = await _db.db.rawQuery(
        'SELECT COALESCE(SUM(qty_on_hand),0) AS q, COALESCE(SUM(qty_on_hand*avg_unit_cost),0) AS v, '
        'COALESCE(MAX(avg_unit_cost),0) AS c FROM stock_balances WHERE item_id = ? AND warehouse_id = ?',
        [itemId, warehouseId]);
    final q = (rows.first['q'] as num).toDouble();
    final v = (rows.first['v'] as num).toDouble();
    return (qty: q, avgCost: q > 0 ? v / q : (rows.first['c'] as num).toDouble());
  }

  /// Quantity already sold on this device but not yet confirmed by ZARI, per
  /// item — subtracted from cached stock so a cashier offline all day doesn't
  /// oversell what they've already rung up.
  Future<double> pendingPosQty(String itemId, String branchId) async {
    final rows = await _db.db.query('outbox',
        columns: ['body'],
        where: "type = 'pos_sale' AND branch_id = ? AND status IN ('pending','syncing','needs_review','failed')",
        whereArgs: [branchId]);
    var total = 0.0;
    for (final r in rows) {
      final body = jsonDecode(r['body'] as String) as Map<String, dynamic>;
      for (final line in (body['lines'] as List).cast<Map<String, dynamic>>()) {
        if (line['itemId'] == itemId) total += (line['qty'] as num).toDouble();
      }
    }
    return total;
  }

  Future<List<RefRecord>> refList(String entity, {String? branchId, bool activeOnly = true}) async {
    final where = ['entity = ?'];
    final args = <Object?>[entity];
    if (branchId != null) {
      where.add('branch_id = ?');
      args.add(branchId);
    }
    if (activeOnly) where.add("(status IS NULL OR status = 'active')");
    final rows = await _db.db.query('ref_data', where: where.join(' AND '), whereArgs: args, orderBy: 'name');
    return rows.map(RefRecord.fromRow).toList();
  }

  Future<RefRecord?> ref(String entity, String id) async {
    final rows = await _db.db.query('ref_data', where: 'entity = ? AND id = ?', whereArgs: [entity, id]);
    return rows.isEmpty ? null : RefRecord.fromRow(rows.first);
  }

  Future<RefRecord?> company() async {
    final rows = await _db.db.query('ref_data', where: 'entity = ?', whereArgs: [RefEntity.company], limit: 1);
    return rows.isEmpty ? null : RefRecord.fromRow(rows.first);
  }

  Future<List<RefRecord>> searchCustomers(String query, {int limit = 30}) async {
    final q = '%${query.trim()}%';
    final rows = await _db.db.rawQuery(
        "SELECT * FROM ref_data WHERE entity = ? AND (status IS NULL OR status = 'active') "
        "AND (name LIKE ? OR code LIKE ?) ORDER BY name LIMIT ?",
        [RefEntity.customer, q, q, limit]);
    return rows.map(RefRecord.fromRow).toList();
  }
}
