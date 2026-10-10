import '../masterdata/models.dart';
import '../sync/outbox.dart';
import 'sales_calculator.dart';

/// Queues POST /api/sales-orders (CreateSalesOrderCommand), optionally
/// followed by /submit so it lands in the approver's queue. A Sales Order
/// has no stock or GL effect in ZARI, so it's the safest document to
/// capture offline.
Future<OutboxEntry> queueSalesOrder({
  required OutboxRepository outbox,
  required String userId,
  required String branchId,
  required RefRecord customer,
  required DateTime orderDate,
  DateTime? expectedDeliveryDate,
  String? remarks,
  required double headerDiscountPct,
  required List<CartLine> lines,
  bool submitForApproval = true,
}) {
  if (lines.isEmpty) throw ArgumentError('At least one item line is required.');
  final id = outbox.newId();
  final totals = CartTotals.of(lines, headerDiscountPct: headerDiscountPct);
  return outbox.enqueue(
    id: id,
    userId: userId,
    branchId: branchId,
    type: OutboxType.salesOrder,
    title: 'Sales order · ${customer.name} · ${lines.length} item(s)',
    path: '/api/sales-orders',
    body: {
      'branchId': branchId,
      'customerId': customer.id,
      'orderDate': orderDate.toUtc().toIso8601String(),
      'expectedDeliveryDate': expectedDeliveryDate?.toUtc().toIso8601String(),
      'remarks': stampRemarks(mobileRef(id), remarks),
      'discountPct': headerDiscountPct > 0 ? headerDiscountPct : null,
      'createdBy': userId,
      'lines': [
        for (final l in lines)
          {
            'itemId': l.item.id,
            'qty': l.qty,
            'uomId': l.item.baseUomId,
            'unitPrice': l.unitPrice,
            'discountPct': l.discountPct,
            'discountSourceType': null,
            'discountSourceId': null,
          }
      ],
    },
    followUpPath: submitForApproval ? '/api/sales-orders/{id}/submit' : null,
    followUpBody: submitForApproval ? {'requestedBy': userId} : null,
    meta: {
      'total': totals.total,
      'customerName': customer.name,
      'lines': [
        for (final l in lines) {'code': l.item.code, 'name': l.item.name, 'qty': l.qty, 'unitPrice': l.unitPrice}
      ],
    },
  );
}
