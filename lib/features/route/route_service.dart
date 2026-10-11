import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_client.dart';
import '../../core/app_database.dart';
import '../masterdata/models.dart';
import '../sales/sales_calculator.dart';
import '../sync/outbox.dart';
import 'route_ledger.dart';
import 'route_models.dart';

/// One trip as the handheld sees it: the latest download, the baseline it tracks from, its events and the ledger.
class RouteTripView {
  const RouteTripView({required this.latest, required this.ledger, required this.series, required this.downloadedAt});

  final TripBundle latest;
  final TripLedger ledger;
  final InvoiceSeries series;
  final DateTime downloadedAt;

  TripInfo get trip => latest.trip;
  String get id => latest.trip.id;

  /// The status the driver is effectively in: an end of trip recorded on the device counts even before it syncs.
  String get status => ledger.ended && trip.status == TripStatus.inTransit ? TripStatus.pendingClose : trip.status;
  bool get onTheRoad => status == TripStatus.inTransit;
}

class SaleLineDraft {
  SaleLineDraft({
    required this.itemId,
    required this.code,
    required this.name,
    required this.uomId,
    required this.vatType,
    required this.qty,
    required this.unitPrice,
    this.discountPct = 0,
    this.salesOrderLineId,
    this.allowNegativeStock = false,
  });

  final String itemId;
  final String code;
  final String name;
  final String uomId;
  final VatType vatType;
  double qty;
  double unitPrice;
  double discountPct;
  final String? salesOrderLineId;
  final bool allowNegativeStock;

  Map<String, dynamic> toEventJson() => {
        'itemId': itemId,
        'itemCode': code,
        'itemName': name,
        'uomId': uomId,
        'vatType': vatTypeCode(vatType),
        'qty': qty,
        'unitPrice': unitPrice,
        'discountPct': discountPct,
        'salesOrderLineId': salesOrderLineId,
      };
}

class RefusalDraft {
  RefusalDraft({required this.salesOrderLineId, required this.itemId, required this.qty, required this.reasonCode, this.notes});

  final String salesOrderLineId;
  final String itemId;
  double qty;
  String reasonCode;
  String? notes;

  Map<String, dynamic> toJson() =>
      {'salesOrderLineId': salesOrderLineId, 'itemId': itemId, 'qty': qty, 'reasonCode': reasonCode, 'notes': notes};
}

class TenderDraft {
  TenderDraft({required this.paymentMethodId, required this.code, required this.name, required this.amount, this.referenceNo});

  final String paymentMethodId;
  final String code;
  final String name;
  double amount;
  String? referenceNo;

  bool get isCash => code.toUpperCase() == 'CASH';
}

class SaleDraft {
  SaleDraft({
    required this.tripId,
    required this.customerId,
    required this.customerName,
    this.salesOrderId,
    this.headerDiscountPct,
    List<SaleLineDraft>? lines,
    List<RefusalDraft>? refusals,
    List<TenderDraft>? tenders,
    this.receivedByName,
  })  : lines = lines ?? [],
        refusals = refusals ?? [],
        tenders = tenders ?? [];

  final String tripId;
  final String customerId;
  final String customerName;
  final String? salesOrderId;
  final double? headerDiscountPct;
  final List<SaleLineDraft> lines;
  final List<RefusalDraft> refusals;
  final List<TenderDraft> tenders;
  String? receivedByName;
}

/// Totals and the money split of a sale, computed exactly like ZARI does.
class SaleFigures {
  const SaleFigures({required this.totals, required this.tendered, required this.change, required this.applied, required this.cashKept});

  final CartTotals totals;
  final double tendered;
  final double change;

  /// Paid against the invoice (≤ total); the rest is charged to the customer's account.
  final double applied;
  final double cashKept;

  double get charged => round4(totals.total - applied);
}

/// The figures plus every reason ZARI would refuse the sale — checked before a number is used, because once the
/// invoice is printed it can't be taken back except by voiding the number.
class SaleCheck {
  const SaleCheck(this.figures, this.errors);
  final SaleFigures figures;
  final List<String> errors;
  bool get ok => errors.isEmpty;
}

SaleCheck checkSale(TripLedger ledger, SaleDraft d, {required bool onTheRoad}) {
  final errors = <String>[];
  if (!onTheRoad) errors.add('Sales can only be recorded while the trip is on the road.');
  final lines = d.lines.where((l) => l.qty > 0).toList();
  if (lines.isEmpty) errors.add('Add at least one item with a quantity.');

  // Order lines: never more than is open; whatever of the order isn't delivered needs a reason.
  if (d.salesOrderId != null) {
    final order = ledger.baseline.salesOrders.where((o) => o.id == d.salesOrderId).firstOrNull;
    if (order == null) {
      errors.add('That sales order is not on this trip.');
    } else {
      for (final ol in order.lines) {
        final open = ledger.orderLineOpen(ol.salesOrderLineId);
        if (open <= 0.00001) continue;
        final delivered = lines.where((l) => l.salesOrderLineId == ol.salesOrderLineId).fold(0.0, (s, l) => s + l.qty);
        final refused = d.refusals.where((r) => r.salesOrderLineId == ol.salesOrderLineId).fold(0.0, (s, r) => s + r.qty);
        final code = ledger.items[ol.itemId]?.code ?? 'An item';
        if (delivered > open + 0.00001) {
          errors.add('$code: only ${_q(open)} still to deliver on ${order.soNo}.');
        } else if (delivered + refused > open + 0.00001) {
          errors.add('$code: delivered + not delivered is more than the ${_q(open)} open.');
        } else if (open - delivered - refused > 0.00001) {
          errors.add('$code: ${_q(open - delivered - refused)} not delivered — choose a reason.');
        }
      }
    }
  }
  for (final r in d.refusals.where((r) => r.qty > 0)) {
    if (r.reasonCode.isEmpty) errors.add('Choose why ${ledger.items[r.itemId]?.code ?? 'an item'} was not all delivered.');
    if (r.reasonCode == RefusalReason.other && (r.notes ?? '').trim().isEmpty) {
      errors.add('Explain "Other" in the notes.');
    }
  }

  // Stock on the truck.
  final byItem = <String, double>{};
  for (final l in lines) {
    byItem[l.itemId] = (byItem[l.itemId] ?? 0) + l.qty;
  }
  for (final entry in byItem.entries) {
    final line = lines.firstWhere((l) => l.itemId == entry.key);
    final onTruck = ledger.onTruck(entry.key);
    if (entry.value > onTruck + 0.00001 && !line.allowNegativeStock) {
      errors.add('${line.code}: only ${_q(onTruck)} on the truck.');
    }
  }

  // Money: change only from one cash tender; anything unpaid must fit the customer's credit limit.
  final totals = CartTotals.of([
    for (final l in lines)
      CartLine(
        key: l.itemId,
        item: Item(
            id: l.itemId,
            code: l.code,
            name: l.name,
            baseUomId: l.uomId,
            vatType: l.vatType,
            status: 'active',
            isSold: true,
            isStocked: true,
            isSerialized: false,
            isBatchTracked: false,
            allowNegativeStock: l.allowNegativeStock),
        qty: l.qty,
        unitPrice: l.unitPrice,
        discountPct: l.discountPct,
      ),
  ], headerDiscountPct: d.headerDiscountPct ?? 0);
  final tenders = d.tenders.where((t) => t.amount > 0).toList();
  final tendered = round4(tenders.fold(0.0, (s, t) => s + t.amount));
  final change = tendered > totals.total ? round4(tendered - totals.total) : 0.0;
  if (change > 0 && !tenders.any((t) => t.isCash && t.amount >= change)) {
    errors.add('Change can only be given out of a cash payment that covers it.');
  }
  for (final t in tenders.where((t) => !t.isCash)) {
    if ((t.referenceNo ?? '').trim().isEmpty) errors.add('${t.name} needs a reference number.');
  }
  final cashKept = round4(tenders.where((t) => t.isCash).fold(0.0, (s, t) => s + t.amount) - change);
  final applied = tendered < totals.total ? tendered : totals.total;
  final unpaid = round4(totals.total - applied);
  final stop = ledger.baseline.stopFor(d.customerId);
  if (unpaid > 0 && stop?.creditLimit != null) {
    final owes = ledger.customerOwes(d.customerId);
    if (owes + unpaid > stop!.creditLimit! + 0.00001) {
      errors.add('${d.customerName} would owe ${(owes + unpaid).toStringAsFixed(2)}, over their credit limit of '
          '${stop.creditLimit!.toStringAsFixed(2)}. Collect more now.');
    }
  }

  return SaleCheck(SaleFigures(totals: totals, tendered: tendered, change: change, applied: applied, cashKept: cashKept), errors);
}

String _q(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// The Route module's storage and actions. Every action that records something does it in one SQLite transaction:
/// the invoice number (if any), the local event and the outbox row — so a number is never used twice, never skipped
/// silently, and the ledger and the sync queue can't disagree.
class RouteService {
  RouteService(this._db, this._outbox, this._api, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final OutboxRepository _outbox;
  final ApiClient _api;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  Database get _sql => _db.db;

  // ------------------------------------------------------------------ download

  /// GET /api/trips/mine → local store. Returns how many trips are on the road for this driver.
  Future<int> download(String userId) async {
    final res = await _api.get<dynamic>('/api/trips/mine');
    final bundles = [for (final b in (res as List)) b as Map<String, dynamic>];
    await saveBundles(userId, bundles);
    return bundles.length;
  }

  Future<void> saveBundles(String userId, List<Map<String, dynamic>> bundles) async {
    final now = _clock().toUtc().toIso8601String();
    await _sql.transaction((txn) async {
      final keep = <String>[];
      for (final json in bundles) {
        final bundle = TripBundle.fromJson(json);
        keep.add(bundle.trip.id);
        final hasEvents = Sqflite.firstIntValue(
                await txn.rawQuery('SELECT COUNT(*) FROM route_events WHERE trip_id = ?', [bundle.trip.id]))! >
            0;
        final existing = await txn.query('route_trips', where: 'id = ?', whereArgs: [bundle.trip.id]);
        // The baseline moves to the server's latest only while the device has recorded nothing on the trip.
        final baseline = hasEvents && existing.isNotEmpty ? existing.first['baseline'] as String? : jsonEncode(json);
        await txn.insert(
            'route_trips',
            {
              'id': bundle.trip.id,
              'user_id': userId,
              'status': bundle.trip.status,
              'bundle': jsonEncode(json),
              'baseline': baseline ?? jsonEncode(json),
              'downloaded_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);

        final series = InvoiceSeries.parse(bundle.nextInvoiceNumber);
        final current = await txn.query('route_series', where: 'terminal_id = ?', whereArgs: [bundle.trip.posTerminalId]);
        final localNext = current.isEmpty ? 0 : current.first['next_number'] as int;
        final samePrefix = current.isNotEmpty && current.first['prefix'] == series.prefix;
        await txn.insert(
            'route_series',
            {
              'terminal_id': bundle.trip.posTerminalId,
              'prefix': series.prefix,
              'padding': series.padding,
              // Only ever forward: numbers this device used but ZARI hasn't seen yet stay used.
              'next_number': samePrefix && localNext > series.next ? localNext : series.next,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // Trips that are no longer on the road (closed in ZARI) drop off the device; their events stay as history.
      await txn.delete('route_trips',
          where: 'user_id = ? ${keep.isEmpty ? '' : 'AND id NOT IN (${List.filled(keep.length, '?').join(',')})'}',
          whereArgs: [userId, ...keep]);
    });
  }

  Future<List<RouteTripView>> trips(String userId) async {
    final rows = await _sql.query('route_trips', where: 'user_id = ?', whereArgs: [userId], orderBy: 'downloaded_at DESC');
    return [for (final r in rows) await _view(r)];
  }

  Future<RouteTripView?> trip(String tripId) async {
    final rows = await _sql.query('route_trips', where: 'id = ?', whereArgs: [tripId]);
    return rows.isEmpty ? null : _view(rows.first);
  }

  Future<RouteTripView> _view(Map<String, Object?> row) async {
    final latest = TripBundle.fromJson(jsonDecode(row['bundle'] as String) as Map<String, dynamic>);
    final baseline = TripBundle.fromJson(jsonDecode((row['baseline'] ?? row['bundle']) as String) as Map<String, dynamic>);
    final events = await this.events(latest.trip.id);
    final seriesRow = (await _sql.query('route_series', where: 'terminal_id = ?', whereArgs: [latest.trip.posTerminalId])).first;
    return RouteTripView(
      latest: latest,
      ledger: TripLedger.compute(baseline, events),
      series: InvoiceSeries(
          prefix: seriesRow['prefix'] as String, padding: seriesRow['padding'] as int, next: seriesRow['next_number'] as int),
      downloadedAt: DateTime.parse(row['downloaded_at'] as String),
    );
  }

  Future<List<RouteEvent>> events(String tripId) async {
    final rows = await _sql.query('route_events', where: 'trip_id = ?', whereArgs: [tripId], orderBy: 'created_at ASC');
    return [
      for (final r in rows)
        RouteEvent(
          id: r['id'] as String,
          tripId: r['trip_id'] as String,
          kind: r['kind'] as String,
          invoiceNumber: r['invoice_number'] as String?,
          data: jsonDecode(r['data'] as String) as Map<String, dynamic>,
          outboxId: r['outbox_id'] as String?,
          createdAt: DateTime.parse(r['created_at'] as String),
        )
    ];
  }

  // ------------------------------------------------------------------ load

  /// LOADED → IN_TRANSIT. Done at the warehouse, online: sales can't start until ZARI has it.
  Future<List<Map<String, dynamic>>> acceptLoad(String userId, String tripId, Map<String, double> counts) async {
    final res = await _api.post<dynamic>('/api/trips/$tripId/accept-load', {
      'counts': [for (final c in counts.entries) {'itemId': c.key, 'qtyCounted': c.value}],
    });
    await download(userId);
    final discrepancies = (res is Map ? res['discrepancies'] as List? : null) ?? const [];
    return [for (final d in discrepancies) d as Map<String, dynamic>];
  }

  // ------------------------------------------------------------------ sale

  /// Records an invoice issued at a stop: claims the next number, the local event and the outbox row, atomically.
  /// Throws [StateError] with the reasons when ZARI would refuse it.
  Future<RouteEvent> recordSale(String userId, SaleDraft d, {double? latitude, double? longitude}) async {
    final view = (await trip(d.tripId))!;
    final check = checkSale(view.ledger, d, onTheRoad: view.onTheRoad);
    if (!check.ok) throw StateError(check.errors.join('\n'));
    final f = check.figures;
    final soldAt = _clock().toUtc();
    final lines = d.lines.where((l) => l.qty > 0).toList();
    final refusals = d.refusals.where((r) => r.qty > 0).toList();
    final tenders = d.tenders.where((t) => t.amount > 0).toList();

    return _sql.transaction((txn) async {
      final number = await _claimNumber(txn, view.trip.posTerminalId);
      final outboxId = _outbox.newId();
      final body = {
        'tripId': d.tripId,
        'birOrSeriesNumber': number,
        'customerId': d.customerId,
        'salesOrderId': d.salesOrderId,
        'soldAt': soldAt.toIso8601String(),
        'discountPct': d.headerDiscountPct,
        'lines': [
          for (final l in lines)
            {
              'itemId': l.itemId,
              'qty': l.qty,
              'unitPrice': l.unitPrice,
              'discountPct': l.discountPct,
              'salesOrderLineId': l.salesOrderLineId,
            }
        ],
        'tenders': [
          for (final t in tenders)
            {'paymentMethodId': t.paymentMethodId, 'amount': t.amount, 'referenceNo': t.referenceNo, 'bankOrPartnerName': null}
        ],
        'receivedByName': (d.receivedByName ?? '').trim().isEmpty ? null : d.receivedByName!.trim(),
        'latitude': latitude,
        'longitude': longitude,
        'refusals': [
          for (final r in refusals)
            {'salesOrderLineId': r.salesOrderLineId, 'qty': r.qty, 'reasonCode': r.reasonCode, 'notes': r.notes}
        ],
      };
      final data = {
        'customerId': d.customerId,
        'customerName': d.customerName,
        'salesOrderId': d.salesOrderId,
        'soNo': view.ledger.baseline.salesOrders.where((o) => o.id == d.salesOrderId).firstOrNull?.soNo,
        'headerDiscountPct': d.headerDiscountPct,
        'lines': [for (final l in lines) l.toEventJson()],
        'refusals': [for (final r in refusals) r.toJson()],
        'tenders': [
          for (final t in tenders) {'code': t.code, 'name': t.name, 'amount': t.amount, 'referenceNo': t.referenceNo}
        ],
        'total': f.totals.total,
        'vatableSales': f.totals.vatableSales,
        'vatExemptSales': f.totals.vatExemptSales,
        'zeroRatedSales': f.totals.zeroRatedSales,
        'vat': f.totals.vat,
        'discount': f.totals.discount,
        'tendered': f.tendered,
        'change': f.change,
        'applied': f.applied,
        'charged': f.charged,
        'cashKept': f.cashKept,
        'receivedByName': body['receivedByName'],
        'soldAt': soldAt.toIso8601String(),
        'printCount': 0,
      };
      await _outbox.enqueue(
        id: outboxId,
        txn: txn,
        userId: userId,
        branchId: view.trip.branchId,
        type: OutboxType.routeSale,
        title: '$number · ${d.customerName}',
        path: '/api/trips/${d.tripId}/route-sales',
        body: body,
        meta: {'tripId': d.tripId, 'total': f.totals.total, 'invoiceNumber': number},
        idempotent: true,
      );
      return _insertEvent(txn, d.tripId, RouteEventKind.sale, data, outboxId: outboxId, invoiceNumber: number, at: soldAt);
    });
  }

  /// Voids an invoice that was printed but must not stand (printer jam, wrong customer) — only while it hasn't
  /// reached ZARI. Its queued sale becomes a void of the same number in the same queue position, so the series
  /// still reaches ZARI in order. Once synced, it has to be reversed with a return in ZARI instead.
  Future<RouteEvent> voidSale(RouteEvent sale, String reason) async {
    if (reason.trim().isEmpty) throw StateError('Give a reason for voiding.');
    final view = await trip(sale.tripId);
    final collected = view?.ledger.events.any((e) =>
            e.kind == RouteEventKind.collection &&
            (e.data['allocations'] as List? ?? const []).any((a) => (a as Map)['invoiceNumber'] == sale.invoiceNumber)) ??
        false;
    if (collected) {
      throw StateError('A collection was already applied to ${sale.invoiceNumber}, so it can no longer be voided.');
    }
    final entry = sale.outboxId == null ? null : await _outbox.get(sale.outboxId!);
    if (entry == null || entry.status == OutboxStatus.synced || entry.status == OutboxStatus.syncing || entry.serverId != null) {
      throw StateError('Invoice ${sale.invoiceNumber} is already in ZARI — reverse it with a sales return in ZARI web instead.');
    }
    return _sql.transaction((txn) async {
      final changed = await txn.update(
          'outbox',
          {
            'type': OutboxType.routeVoid,
            'title': '${sale.invoiceNumber} · voided',
            'path': '/api/trips/${sale.tripId}/route-sales/void',
            'body': jsonEncode({'birOrSeriesNumber': sale.invoiceNumber, 'reason': reason.trim()}),
            'meta': jsonEncode({'tripId': sale.tripId, 'invoiceNumber': sale.invoiceNumber}),
            'status': 'pending',
            'last_error': null,
            'updated_at': _clock().toUtc().toIso8601String(),
          },
          where: "id = ? AND status IN ('pending', 'failed', 'needs_review') AND server_id IS NULL",
          whereArgs: [entry.id]);
      if (changed != 1) throw StateError('Invoice ${sale.invoiceNumber} is being sent to ZARI right now — try again in a moment.');
      final data = {...sale.data, 'voidReason': reason.trim(), 'voidedAt': _clock().toUtc().toIso8601String()};
      await txn.update('route_events', {'kind': RouteEventKind.voidNumber, 'data': jsonEncode(data)},
          where: 'id = ?', whereArgs: [sale.id]);
      // Built here rather than re-read: inside a transaction only `txn` may touch the database.
      return RouteEvent(
          id: sale.id,
          tripId: sale.tripId,
          kind: RouteEventKind.voidNumber,
          data: data,
          invoiceNumber: sale.invoiceNumber,
          outboxId: sale.outboxId,
          createdAt: sale.createdAt);
    });
  }

  /// Voids the next number without a sale (e.g. a blank/spoiled printout), keeping the series unbroken.
  Future<RouteEvent> voidNextNumber(String userId, String tripId, String reason) async {
    if (reason.trim().isEmpty) throw StateError('Give a reason for voiding.');
    final view = (await trip(tripId))!;
    return _sql.transaction((txn) async {
      final number = await _claimNumber(txn, view.trip.posTerminalId);
      final outboxId = _outbox.newId();
      await _outbox.enqueue(
        id: outboxId,
        txn: txn,
        userId: userId,
        branchId: view.trip.branchId,
        type: OutboxType.routeVoid,
        title: '$number · voided',
        path: '/api/trips/$tripId/route-sales/void',
        body: {'birOrSeriesNumber': number, 'reason': reason.trim()},
        meta: {'tripId': tripId, 'invoiceNumber': number},
        idempotent: true,
      );
      return _insertEvent(txn, tripId, RouteEventKind.voidNumber, {'voidReason': reason.trim()},
          outboxId: outboxId, invoiceNumber: number);
    });
  }

  /// From Sync & Queue: void a printed invoice that ZARI rejected, so the series can continue (its later invoices
  /// were held back behind it).
  Future<RouteEvent> voidRejectedSale(OutboxEntry entry, String reason) async {
    final rows = await _sql.query('route_events', where: 'outbox_id = ?', whereArgs: [entry.id]);
    if (rows.isEmpty) throw StateError('This invoice is not on the device any more.');
    final sale = (await events(rows.first['trip_id'] as String)).firstWhere((e) => e.outboxId == entry.id);
    return voidSale(sale, reason);
  }

  /// From Sync & Queue: drop a route action that will never go through. Invoice numbers can't be dropped (that
  /// would leave a gap in the BIR series) — void them instead. Dropping also takes the action out of the ledger.
  Future<void> discardRouteEntry(OutboxEntry entry) async {
    if (entry.type == OutboxType.routeSale || entry.type == OutboxType.routeVoid) {
      throw StateError('An invoice number cannot be discarded — void it so the series stays unbroken.');
    }
    await _sql.transaction((txn) async {
      final deleted = await txn.delete('outbox', where: "id = ? AND status != 'synced'", whereArgs: [entry.id]);
      if (deleted == 1) await txn.delete('route_events', where: 'outbox_id = ?', whereArgs: [entry.id]);
    });
  }

  Future<void> markPrinted(RouteEvent sale) async {
    await _sql.update('route_events', {'data': jsonEncode({...sale.data, 'printCount': (sale.data['printCount'] as int? ?? 0) + 1})},
        where: 'id = ?', whereArgs: [sale.id]);
  }

  // ------------------------------------------------------------------ refusal, return, collection, end

  /// A stop where the customer accepted none of (part of) their order — no invoice number is used.
  Future<RouteEvent> recordRefusal(String userId, String tripId, String customerId, String customerName, String salesOrderId,
      List<RefusalDraft> lines) async {
    final view = (await trip(tripId))!;
    final kept = lines.where((l) => l.qty > 0).toList();
    if (!view.onTheRoad) throw StateError('The trip is not on the road.');
    if (kept.isEmpty) throw StateError('Enter what was refused.');
    for (final l in kept) {
      if (l.qty > view.ledger.orderLineOpen(l.salesOrderLineId) + 0.00001) throw StateError('More than is still open on the order.');
      if (l.reasonCode == RefusalReason.other && (l.notes ?? '').trim().isEmpty) throw StateError('Explain "Other" in the notes.');
    }
    final clientRef = _uuid.v4();
    return _record(userId, view, RouteEventKind.refusal, OutboxType.routeRefusal, '/api/trips/$tripId/refusals',
        title: 'Not delivered · $customerName',
        body: {
          'clientRef': clientRef,
          'customerId': customerId,
          'salesOrderId': salesOrderId,
          'refusedAt': _clock().toUtc().toIso8601String(),
          'lines': [
            for (final l in kept) {'salesOrderLineId': l.salesOrderLineId, 'qty': l.qty, 'reasonCode': l.reasonCode, 'notes': l.notes}
          ],
        },
        data: {'customerId': customerId, 'customerName': customerName, 'salesOrderId': salesOrderId, 'lines': [for (final l in kept) l.toJson()]});
  }

  /// Goods a customer hands back onto the truck (good ones are sellable again; damaged go to the Damaged warehouse at close).
  Future<RouteEvent> recordReturn(String userId, String tripId, String customerId, String customerName,
      List<SaleLineDraft> lines, Map<String, bool> damaged, String? reason) async {
    final view = (await trip(tripId))!;
    final kept = lines.where((l) => l.qty > 0).toList();
    if (!view.onTheRoad) throw StateError('The trip is not on the road.');
    if (kept.isEmpty) throw StateError('Enter what was returned.');
    return _record(userId, view, RouteEventKind.customerReturn, OutboxType.routeReturn, '/api/trips/$tripId/returns',
        title: 'Return · $customerName',
        body: {
          'clientRef': _uuid.v4(),
          'customerId': customerId,
          'returnedAt': _clock().toUtc().toIso8601String(),
          'reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
          'lines': [
            for (final l in kept) {'itemId': l.itemId, 'qty': l.qty, 'unitPrice': l.unitPrice, 'isDamaged': damaged[l.itemId] == true}
          ],
        },
        data: {
          'customerId': customerId,
          'customerName': customerName,
          'reason': reason,
          'lines': [for (final l in kept) {...l.toEventJson(), 'isDamaged': damaged[l.itemId] == true}],
        });
  }

  /// Payment of what the customer owes, allocated oldest first: invoices open at download, then charges issued on
  /// this trip (less earlier collections here).
  Future<RouteEvent> recordCollection(String userId, String tripId, String customerId, String customerName, TenderDraft tender) async {
    final view = (await trip(tripId))!;
    if (!view.onTheRoad) throw StateError('The trip is not on the road.');
    if (tender.amount <= 0) throw StateError('Enter the amount collected.');
    if (!tender.isCash && (tender.referenceNo ?? '').trim().isEmpty) throw StateError('${tender.name} needs a reference number.');
    final allocations = collectionAllocations(view, customerId, tender.amount);
    final allocated = allocations.fold(0.0, (s, a) => s + (a['amount'] as double));
    if (allocated + 0.00001 < tender.amount) {
      throw StateError('Only ${allocated.toStringAsFixed(2)} is open on invoices known to this device.');
    }
    return _record(userId, view, RouteEventKind.collection, OutboxType.routeCollection, '/api/trips/$tripId/collections',
        title: 'Collection · $customerName',
        body: {
          'clientRef': _uuid.v4(),
          'customerId': customerId,
          'collectedAt': _clock().toUtc().toIso8601String(),
          'allocations': allocations,
          'tenders': [
            {'paymentMethodId': tender.paymentMethodId, 'amount': tender.amount, 'referenceNo': tender.referenceNo, 'bankOrPartnerName': null}
          ],
        },
        data: {
          'customerId': customerId,
          'customerName': customerName,
          'amount': tender.amount,
          'cashAmount': tender.isCash ? tender.amount : 0,
          'method': tender.name,
          'allocations': allocations,
        });
  }

  /// Oldest-first allocation of [amount] to the customer's invoices: those open at download (by ZARI id), then the
  /// charges issued on this trip — by invoice number, since they have no ZARI id on the device until they sync;
  /// ZARI resolves the number (the sale always reaches it before the collection).
  List<Map<String, dynamic>> collectionAllocations(RouteTripView view, String customerId, double amount) {
    final paid = <String, double>{};
    for (final e in view.ledger.events.where((e) => e.kind == RouteEventKind.collection && e.customerId == customerId)) {
      for (final a in (e.data['allocations'] as List? ?? const [])) {
        final m = a as Map<String, dynamic>;
        final key = _allocationKey(m);
        paid[key] = (paid[key] ?? 0) + (m['amount'] as num).toDouble();
      }
    }
    final candidates = <(Map<String, dynamic> ref, double balance, String label)>[
      for (final inv in view.ledger.baseline.stopFor(customerId)?.openInvoices ?? const <OpenInvoiceInfo>[])
        ({'salesInvoiceId': inv.salesInvoiceId}, inv.balance, inv.label),
      for (final sale in view.ledger.events.where((e) => e.kind == RouteEventKind.sale && e.customerId == customerId))
        if (sale.amount('charged') > 0.00001 && sale.invoiceNumber != null)
          ({'invoiceNumber': sale.invoiceNumber}, sale.amount('charged'), '${sale.invoiceNumber} (this trip)'),
    ];
    final result = <Map<String, dynamic>>[];
    var left = amount;
    for (final (ref, balance, label) in candidates) {
      if (left <= 0.00001) break;
      final open = round4(balance - (paid[_allocationKey(ref)] ?? 0));
      if (open <= 0.00001) continue;
      final take = round4(open < left ? open : left);
      result.add({...ref, 'amount': take, 'label': label});
      left = round4(left - take);
    }
    return result;
  }

  static String _allocationKey(Map<String, dynamic> allocation) =>
      allocation['salesInvoiceId'] as String? ?? 'no:${allocation['invoiceNumber']}';

  /// IN_TRANSIT → PENDING_CLOSE_APPROVAL: what's left on the truck and the cash handed in.
  Future<RouteEvent> endTrip(String userId, String tripId, Map<String, double> counts, double cashRemitted) async {
    final view = (await trip(tripId))!;
    if (!view.onTheRoad) throw StateError('The trip is not on the road.');
    final missing = view.ledger.countSheet.where((i) => !counts.containsKey(i.itemId)).map((i) => i.code).toList();
    if (missing.isNotEmpty) throw StateError('Count every item: ${missing.join(', ')}.');
    if (cashRemitted < 0) throw StateError('Cash handed in cannot be negative.');
    return _record(userId, view, RouteEventKind.end, OutboxType.routeEnd, '/api/trips/$tripId/end',
        title: 'End of trip ${view.trip.tripNo}',
        body: {
          'cashRemitted': cashRemitted,
          'counts': [for (final c in counts.entries) {'itemId': c.key, 'qtyCounted': c.value}],
        },
        data: {'cashRemitted': cashRemitted, 'counts': counts, 'cashExpected': view.ledger.cashExpected},
        // Ending is not keyed server-side (a repeat is refused, harmlessly) — but a lost answer must not be repeated blindly.
        idempotent: false);
  }

  /// Saves the customer's signature and queues it for upload once the sale itself is in ZARI.
  Future<void> attachSignature(String userId, RouteEvent sale, Uint8List png, String? receivedByName) async {
    final dir = Directory(p.join(await getDatabasesPath(), 'pod'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(p.join(dir.path, '${sale.invoiceNumber ?? sale.id}.png'));
    await file.writeAsBytes(png, flush: true);
    final view = (await trip(sale.tripId))!;
    await _outbox.enqueue(
      userId: userId,
      branchId: view.trip.branchId,
      type: OutboxType.routePod,
      title: 'Signature · ${sale.invoiceNumber}',
      path: '/api/route-sales/{saleId}/pod',
      body: {'signatureFile': file.path, 'receivedByName': receivedByName},
      meta: {'tripId': sale.tripId, 'dependsOn': sale.outboxId},
      idempotent: true,
    );
    await _sql.update('route_events', {'data': jsonEncode({...sale.data, 'signature': file.path, 'receivedByName': receivedByName})},
        where: 'id = ?', whereArgs: [sale.id]);
  }

  // ------------------------------------------------------------------ helpers

  Future<RouteEvent> _record(String userId, RouteTripView view, String kind, String type, String path,
      {required String title, required Map<String, dynamic> body, required Map<String, dynamic> data, bool idempotent = true}) {
    return _sql.transaction((txn) async {
      final outboxId = _outbox.newId();
      await _outbox.enqueue(
        id: outboxId,
        txn: txn,
        userId: userId,
        branchId: view.trip.branchId,
        type: type,
        title: title,
        path: path,
        body: body,
        meta: {'tripId': view.id, if (data['amount'] != null) 'total': data['amount']},
        idempotent: idempotent,
      );
      return _insertEvent(txn, view.id, kind, data, outboxId: outboxId);
    });
  }

  Future<String> _claimNumber(Transaction txn, String terminalId) async {
    final row = (await txn.query('route_series', where: 'terminal_id = ?', whereArgs: [terminalId])).first;
    final series = InvoiceSeries(prefix: row['prefix'] as String, padding: row['padding'] as int, next: row['next_number'] as int);
    await txn.update('route_series', {'next_number': series.next + 1}, where: 'terminal_id = ?', whereArgs: [terminalId]);
    return series.nextFormatted;
  }

  Future<RouteEvent> _insertEvent(Transaction txn, String tripId, String kind, Map<String, dynamic> data,
      {String? outboxId, String? invoiceNumber, DateTime? at}) async {
    final event = RouteEvent(
      id: _uuid.v4(),
      tripId: tripId,
      kind: kind,
      data: data,
      invoiceNumber: invoiceNumber,
      outboxId: outboxId,
      createdAt: (at ?? _clock()).toUtc(),
    );
    await txn.insert('route_events', {
      'id': event.id,
      'trip_id': tripId,
      'kind': kind,
      'invoice_number': invoiceNumber,
      'data': jsonEncode(data),
      'outbox_id': outboxId,
      'created_at': event.createdAt.toIso8601String(),
    });
    return event;
  }
}
