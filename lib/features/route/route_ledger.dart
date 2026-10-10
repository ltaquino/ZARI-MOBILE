import 'route_models.dart';

/// What the driver did on this device. Stored in `route_events`; replayed on top of the trip as first tracked
/// (the baseline) to know, offline, exactly what is on the truck and what each order and customer still has open.
abstract final class RouteEventKind {
  static const sale = 'sale';
  static const voidNumber = 'void';
  static const refusal = 'refusal';
  static const customerReturn = 'return';
  static const collection = 'collection';
  static const end = 'end';
}

class RouteEvent {
  const RouteEvent({
    required this.id,
    required this.tripId,
    required this.kind,
    required this.data,
    required this.createdAt,
    this.invoiceNumber,
    this.outboxId,
  });

  final String id;
  final String tripId;
  final String kind;
  final String? invoiceNumber;
  final Map<String, dynamic> data;
  final String? outboxId;
  final DateTime createdAt;

  String? get customerId => data['customerId'] as String?;
  List<Map<String, dynamic>> get lines => [for (final l in (data['lines'] as List? ?? const [])) l as Map<String, dynamic>];
  List<Map<String, dynamic>> get refusals =>
      [for (final l in (data['refusals'] as List? ?? const [])) l as Map<String, dynamic>];
  double amount(String key) => (data[key] as num?)?.toDouble() ?? 0;
}

/// An item the truck carries now (or has carried this trip).
class TruckItem {
  TruckItem({required this.itemId, required this.code, required this.name, required this.uomId});

  final String itemId;
  final String code;
  final String name;
  final String uomId;
  double loaded = 0;
  double onTruck = 0;
  double delivered = 0;
  double vanSold = 0;
  double refused = 0;
  double returnedGood = 0;
  double returnedDamaged = 0;
}

/// Offline view of one trip: baseline (server state when tracking began) + every local event since.
class TripLedger {
  TripLedger._(this.baseline, this.events);

  final TripBundle baseline;
  final List<RouteEvent> events;

  final Map<String, TruckItem> items = {};
  final Map<String, double> _orderLineOpen = {};
  final Map<String, double> _customerOwed = {};
  double cashExpected = 0;
  double salesTotal = 0;
  int invoiceCount = 0;
  int voidCount = 0;
  bool ended = false;

  static TripLedger compute(TripBundle baseline, List<RouteEvent> events) {
    final l = TripLedger._(baseline, events);
    l._replay();
    return l;
  }

  void _replay() {
    for (final line in baseline.trip.lines) {
      items[line.itemId] = TruckItem(itemId: line.itemId, code: line.itemCode, name: line.itemName, uomId: line.uomId)
        ..loaded = line.qtyLoaded
        ..onTruck = line.qtyExpectedOnTruck
        ..delivered = line.qtyDelivered
        ..vanSold = line.qtyVanSold
        ..refused = line.qtyRefused
        ..returnedGood = line.qtyReturnedGood
        ..returnedDamaged = line.qtyReturnedDamaged;
    }
    for (final order in baseline.salesOrders) {
      for (final line in order.lines) {
        _orderLineOpen[line.salesOrderLineId] = line.qtyRemaining;
      }
    }
    for (final stop in baseline.stops) {
      _customerOwed[stop.customerId] = stop.openBalance;
    }
    cashExpected = baseline.trip.cashExpected;

    for (final e in events) {
      switch (e.kind) {
        case RouteEventKind.sale:
          invoiceCount++;
          salesTotal += e.amount('total');
          cashExpected += e.amount('cashKept');
          _owe(e.customerId, e.amount('total') - e.amount('applied'));
          for (final line in e.lines) {
            final item = _item(line);
            final q = (line['qty'] as num).toDouble();
            item.onTruck -= q;
            if (line['salesOrderLineId'] != null) {
              item.delivered += q;
              _openLess(line['salesOrderLineId'] as String, q);
            } else {
              item.vanSold += q;
            }
          }
          _applyRefusals(e.refusals);
        case RouteEventKind.voidNumber:
          voidCount++;
        case RouteEventKind.refusal:
          _applyRefusals(e.lines);
        case RouteEventKind.customerReturn:
          for (final line in e.lines) {
            final item = _item(line);
            final q = (line['qty'] as num).toDouble();
            if (line['isDamaged'] == true) {
              item.returnedDamaged += q;
            } else {
              item.returnedGood += q;
              item.onTruck += q;
            }
          }
        case RouteEventKind.collection:
          cashExpected += e.amount('cashAmount');
          _owe(e.customerId, -e.amount('amount'));
        case RouteEventKind.end:
          ended = true;
      }
    }
  }

  void _applyRefusals(List<Map<String, dynamic>> refusals) {
    for (final r in refusals) {
      final q = (r['qty'] as num).toDouble();
      _openLess(r['salesOrderLineId'] as String, q);
      final item = items[r['itemId']];
      if (item != null) item.refused += q;
    }
  }

  TruckItem _item(Map<String, dynamic> line) => items.putIfAbsent(
      line['itemId'] as String,
      () => TruckItem(
          itemId: line['itemId'] as String,
          code: line['itemCode'] as String? ?? '',
          name: line['itemName'] as String? ?? '',
          uomId: line['uomId'] as String? ?? ''));

  void _openLess(String soLineId, double q) => _orderLineOpen[soLineId] = (_orderLineOpen[soLineId] ?? 0) - q;

  void _owe(String? customerId, double amount) {
    if (customerId == null) return;
    _customerOwed[customerId] = (_customerOwed[customerId] ?? 0) + amount;
  }

  /// Still to deliver on this trip for a sales-order line.
  double orderLineOpen(String salesOrderLineId) => _orderLineOpen[salesOrderLineId] ?? 0;

  /// What the customer owes now: posted invoices at download + charge sales − collections on this device.
  double customerOwes(String customerId) => _customerOwed[customerId] ?? 0;

  double onTruck(String itemId) => items[itemId]?.onTruck ?? 0;

  /// Orders for a customer that still have something open on this trip.
  List<OrderInfo> openOrdersFor(String customerId) => baseline
      .ordersFor(customerId)
      .where((o) => o.lines.any((l) => orderLineOpen(l.salesOrderLineId) > 0.00001))
      .toList();

  /// What the driver should count when ending: every item, with what should be on the truck.
  List<TruckItem> get countSheet => items.values.where((i) => i.loaded > 0 || i.onTruck > 0 || i.returnedGood > 0).toList()
    ..sort((a, b) => a.code.compareTo(b.code));

  /// A stop is done once the customer has a sale or refusal on this device and nothing of their orders is open.
  bool stopVisited(String customerId) => events.any((e) =>
      (e.kind == RouteEventKind.sale || e.kind == RouteEventKind.refusal) && e.customerId == customerId);
}
