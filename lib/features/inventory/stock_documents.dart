import '../masterdata/models.dart';
import '../sync/outbox.dart';

enum StockDocMode { opname, adjustment }

class StockDocLine {
  StockDocLine({required this.item, required this.systemQty, required this.unitCost, double? countedQty})
      : countedQty = countedQty ?? systemQty;

  final Item item;

  /// Cached on-hand at the moment the line was added (ZARI's own forms
  /// snapshot it the same way). Clamped at 0 — ZARI's validator rejects
  /// negative system quantities.
  final double systemQty;
  final double unitCost;
  double countedQty;
  String? batchNo;
  String? serialNo;

  double get variance => countedQty - systemQty;
}

/// Builds and queues a Stock Opname (POST /api/stock-opnames, saved as
/// DRAFT for a supervisor to post) or a Stock Adjustment (POST
/// /api/stock-adjustments, optionally followed by /submit for approval).
Future<OutboxEntry> queueStockDocument({
  required OutboxRepository outbox,
  required StockDocMode mode,
  required String userId,
  required String branchId,
  required String warehouseId,
  required String warehouseName,
  required DateTime date,
  required List<StockDocLine> lines,
  String? reasonCode,
  String? remarks,
  bool submitForApproval = false,
}) {
  if (lines.isEmpty) throw ArgumentError('At least one item line is required.');
  if (mode == StockDocMode.adjustment && !lines.any((l) => l.variance != 0)) {
    throw ArgumentError('At least one line must change the quantity.');
  }
  final id = outbox.newId();
  final ref = mobileRef(id);
  final isOpname = mode == StockDocMode.opname;

  final body = <String, dynamic>{
    'branchId': branchId,
    'warehouseId': warehouseId,
    isOpname ? 'countDate' : 'adjustmentDate': date.toUtc().toIso8601String(),
    if (!isOpname) 'reasonCode': reasonCode,
    'remarks': stampRemarks(ref, remarks),
    'createdBy': userId,
    // ZARI's idempotency key: a resend returns this same document, so a lost answer is simply retried.
    'clientReferenceId': id,
    'lines': [
      for (final l in lines)
        {
          'itemId': l.item.id,
          'batchNo': _blankToNull(l.batchNo),
          'serialNo': _blankToNull(l.serialNo),
          if (isOpname) ...{'systemQty': l.systemQty, 'countedQty': l.countedQty}
          else ...{'qtyBefore': l.systemQty, 'qtyAfter': l.countedQty},
          'unitCost': l.unitCost,
        }
    ],
  };

  final variances = lines.where((l) => l.variance != 0).length;
  return outbox.enqueue(
    id: id,
    userId: userId,
    branchId: branchId,
    type: isOpname ? OutboxType.stockOpname : OutboxType.stockAdjustment,
    title: '${isOpname ? 'Stock count' : 'Adjustment'} · $warehouseName · ${lines.length} item(s), $variances variance(s)',
    path: isOpname ? '/api/stock-opnames' : '/api/stock-adjustments',
    body: body,
    followUpPath: !isOpname && submitForApproval ? '/api/stock-adjustments/{id}/submit' : null,
    followUpBody: !isOpname && submitForApproval ? {'requestedBy': userId} : null,
    idempotent: true,
    meta: {
      'warehouseName': warehouseName,
      'lines': [
        for (final l in lines) {'code': l.item.code, 'name': l.item.name, 'system': l.systemQty, 'counted': l.countedQty}
      ],
    },
  );
}

String? _blankToNull(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
