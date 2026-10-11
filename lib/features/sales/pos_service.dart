import '../../shared/format.dart';
import '../masterdata/models.dart';
import '../sync/outbox.dart';
import 'sales_calculator.dart';

class Tender {
  Tender({required this.method, required this.amount, this.referenceNo, this.bankOrPartnerName});

  final RefRecord method;
  double amount;
  String? referenceNo;
  String? bankOrPartnerName;

  bool get isCash => method.code.toUpperCase() == 'CASH';
}

/// Mirrors DiscountThresholdPolicy.ExceedsThreshold: the larger of the header
/// discount and the biggest non-statutory line discount must not exceed
/// Company.MaxUnapprovedDiscountPct.
bool exceedsDiscountThreshold(double? maxUnapprovedPct, double headerPct, Iterable<CartLine> lines) {
  if (maxUnapprovedPct == null) return false;
  var max = headerPct;
  for (final l in lines) {
    if (l.statutoryDiscountTypeId == null && l.discountPct > max) max = l.discountPct;
  }
  return max > maxUnapprovedPct;
}

/// Everything CreatePosSaleCommandHandler would reject, checked on the
/// device first. This matters more than usual: that handler commits the
/// invoice, the stock issue and the payment as separate steps, so a sale
/// rejected half-way leaves a partial document behind in ZARI. Refusing
/// offline is far cheaper than cleaning that up.
///
/// [availableQty] = cached on-hand at each item's default warehouse minus
/// what this device already sold but hasn't synced.
List<String> validatePosCart({
  required List<CartLine> lines,
  required double headerDiscountPct,
  required double? maxUnapprovedDiscountPct,
  required Map<String, double> availableQty,
}) {
  final problems = <String>[];
  if (lines.isEmpty) problems.add('Add at least one item.');

  if (exceedsDiscountThreshold(maxUnapprovedDiscountPct, headerDiscountPct, lines)) {
    problems.add('Discounts above ${maxUnapprovedDiscountPct!.toStringAsFixed(2)}% need manager approval and '
        "can't be rung up at POS. Use a Sales Invoice in ZARI web instead.");
  }

  final serials = <String>{};
  for (final l in lines) {
    if (l.qty <= 0) problems.add('${l.item.code}: quantity must be more than zero.');
    if (l.unitPrice < 0) problems.add('${l.item.code}: price cannot be negative.');
    if (l.item.isStocked && l.defaultWarehouseId == null) {
      problems.add('${l.item.code}: no default warehouse at this branch.');
    }
    if (l.item.isSerialized) {
      final sn = (l.serialNo ?? '').trim();
      if (sn.isEmpty) {
        problems.add('${l.item.code}: serial no. required.');
      } else if (!serials.add('${l.item.id}|$sn')) {
        problems.add('${l.item.code}: serial no. $sn is in the cart twice.');
      }
    }
    if (l.statutoryDiscountTypeId != null && (l.statutoryIdNumber ?? '').trim().isEmpty) {
      problems.add('${l.item.code}: ID number required for the statutory discount.');
    }
  }

  // Stock: total qty per item across lines vs what's available.
  final wanted = <String, double>{};
  final byId = <String, CartLine>{};
  for (final l in lines) {
    if (!l.item.isStocked || l.item.allowNegativeStock) continue;
    wanted[l.item.id] = (wanted[l.item.id] ?? 0) + l.qty;
    byId[l.item.id] = l;
  }
  wanted.forEach((itemId, q) {
    final avail = availableQty[itemId] ?? 0;
    if (q > avail + 1e-9) {
      problems.add('${byId[itemId]!.item.code}: only ${qty(avail <= 0 ? 0 : avail)} in stock (as last downloaded).');
    }
  });
  return problems;
}

List<String> validateTenders(List<Tender> tenders, double total) {
  final problems = <String>[];
  if (tenders.isEmpty) problems.add('Add a payment.');
  for (final t in tenders) {
    if (t.amount <= 0) problems.add('${t.method.name}: amount must be more than zero.');
    if (t.method.boolField('requiresReferenceNo') && (t.referenceNo ?? '').trim().isEmpty) {
      problems.add('${t.method.name}: ${t.method.strField('referenceNoLabel') ?? 'reference no.'} is required.');
    }
    if (t.method.boolField('requiresBankOrPartnerName') && (t.bankOrPartnerName ?? '').trim().isEmpty) {
      problems.add('${t.method.name}: bank / partner name is required.');
    }
  }
  final tendered = round4(tenders.fold(0.0, (s, t) => s + t.amount));
  if (tendered + 1e-9 < total) problems.add('Payment is short by ${(total - tendered).toStringAsFixed(2)}.');
  final change = round4(tendered - total);
  if (change > 0 && !tenders.any((t) => t.isCash && t.amount + 1e-9 >= change)) {
    problems.add('Change can only be given from a single cash payment that covers it.');
  }
  return problems;
}

Map<String, dynamic> buildPosCheckoutBody({
  required String branchId,
  required String posTerminalId,
  required String? customerId,
  required DateTime soldAt,
  required double headerDiscountPct,
  required List<CartLine> lines,
  required List<Tender> tenders,
  required String userId,
}) =>
    {
      'branchId': branchId,
      'posTerminalId': posTerminalId,
      'customerId': customerId,
      // The moment of sale, not the moment of sync — an offline sale keeps
      // its real date.
      'invoiceDate': soldAt.toUtc().toIso8601String(),
      'discountPct': headerDiscountPct > 0 ? headerDiscountPct : null,
      'costCenterId': null,
      'lines': [
        for (final l in lines)
          {
            'itemId': l.item.id,
            'qty': l.qty,
            'uomId': l.item.baseUomId,
            'unitPrice': l.unitPrice,
            'discountPct': l.statutoryDiscountTypeId == null ? l.discountPct : 0,
            'vatType': vatTypeCode(l.item.vatType),
            'statutoryDiscountTypeId': l.statutoryDiscountTypeId,
            'statutoryIdNumber': l.statutoryDiscountTypeId == null ? null : l.statutoryIdNumber?.trim(),
            'serialNo': l.item.isSerialized ? l.serialNo?.trim() : null,
          }
      ],
      'tenders': [
        for (final t in tenders)
          {
            'paymentMethodId': t.method.id,
            'amount': round4(t.amount),
            'referenceNo': (t.referenceNo ?? '').trim().isEmpty ? null : t.referenceNo!.trim(),
            'bankOrPartnerName': (t.bankOrPartnerName ?? '').trim().isEmpty ? null : t.bankOrPartnerName!.trim(),
          }
      ],
      'createdBy': userId,
    };

Future<OutboxEntry> queuePosSale({
  required OutboxRepository outbox,
  required String userId,
  required String branchId,
  required RefRecord terminal,
  required RefRecord? customer,
  required double headerDiscountPct,
  required List<CartLine> lines,
  required List<Tender> tenders,
  DateTime? soldAt,
}) {
  final at = soldAt ?? DateTime.now();
  final totals = CartTotals.of(lines, headerDiscountPct: headerDiscountPct);
  final tendered = round4(tenders.fold(0.0, (s, t) => s + t.amount));
  final id = outbox.newId();
  return outbox.enqueue(
    id: id,
    userId: userId,
    branchId: branchId,
    type: OutboxType.posSale,
    title: 'POS sale · ${lines.length} item(s) · ${customer?.name ?? 'Walk-in'}',
    path: '/api/pos/checkout',
    body: {
      ...buildPosCheckoutBody(
        branchId: branchId,
        posTerminalId: terminal.id,
        customerId: customer?.id,
        soldAt: at,
        headerDiscountPct: headerDiscountPct,
        lines: lines,
        tenders: tenders,
        userId: userId,
      ),
      // ZARI's idempotency key: a resend resumes/returns this same sale, so a lost answer is simply retried.
      'clientReferenceId': id,
    },
    idempotent: true,
    meta: {
      'total': totals.total,
      'vatableSales': totals.vatableSales,
      'vatExemptSales': totals.vatExemptSales,
      'zeroRatedSales': totals.zeroRatedSales,
      'vat': totals.vat,
      'discount': totals.discount,
      'tendered': tendered,
      'change': round4(tendered - totals.total),
      'customerName': customer?.name ?? 'Walk-in Customer',
      'terminalCode': terminal.code,
      'soldAt': at.toUtc().toIso8601String(),
      'lines': [
        for (final l in lines)
          {
            'code': l.item.code,
            'name': l.item.name,
            'qty': l.qty,
            'unitPrice': l.unitPrice,
            'net': l.calc.net,
            if (l.statutoryDiscountTypeId != null) 'statutory': true,
          }
      ],
      'tenders': [
        for (final t in tenders) {'method': t.method.name, 'amount': t.amount}
      ],
    },
  );
}
