// Route Sales end-to-end against a REAL running ZARI API — skipped unless ZARI_LIVE_URL is set:
//
//   ZARI_LIVE_URL=http://localhost:5000 flutter test test/live/route_live_test.dart
//
// Plans a trip as admin (truck E2E55464, one sales order + extra stock, driver staff.hq), approves the load as
// manager.hq, then drives the handheld code exactly as the app does: download, accept the load, an invoice that
// delivers part of the order (with a reason for the rest) plus a van sale, a voided number, a customer return —
// all queued offline and synced — then ends the trip and lets the manager close it. Posts real documents.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zari_mobile/core/api_client.dart';
import 'package:zari_mobile/core/app_database.dart';
import 'package:zari_mobile/core/key_value_store.dart';
import 'package:zari_mobile/core/token_store.dart';
import 'package:zari_mobile/features/auth/auth_repository.dart';
import 'package:zari_mobile/features/masterdata/models.dart';
import 'package:zari_mobile/features/route/route_models.dart';
import 'package:zari_mobile/features/route/route_service.dart';
import 'package:zari_mobile/features/sync/outbox.dart';
import 'package:zari_mobile/features/sync/outbox_processor.dart';

Future<(ApiClient, String)> signIn(String url, String email) async {
  final tokens = TokenStore(MemoryKeyValueStore());
  final api = ApiClient(baseUrl: url, tokens: tokens);
  final login = await AuthRepository(api: api, tokens: tokens, kv: MemoryKeyValueStore()).login(email, 'zari123');
  return (api, login.session.userId);
}

void main() {
  final url = Platform.environment['ZARI_LIVE_URL'];

  test('a whole trip from the handheld against a live ZARI', () async {
    final (admin, adminId) = await signIn(url!, 'admin@zari.coop');
    final (manager, managerId) = await signIn(url, 'manager.hq@zari.coop');

    // ---- the device: driver signs in with an empty local store
    sqfliteFfiInit();
    final db = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final driverTokens = TokenStore(MemoryKeyValueStore());
    final driverApi = ApiClient(baseUrl: url, tokens: driverTokens);
    final driver = (await AuthRepository(api: driverApi, tokens: driverTokens, kv: MemoryKeyValueStore()).login('staff.hq@zari.coop', 'zari123')).session;
    final outbox = OutboxRepository(db);
    final route = RouteService(db, outbox, driverApi);
    final push = OutboxProcessor(driverApi, outbox);

    // ---- dispatcher (admin) plans; manager approves the order and the load
    final warehouses = await admin.get<List<dynamic>>('/api/warehouses');
    final main = warehouses.cast<Map<String, dynamic>>().firstWhere((w) => w['code'] == 'HQ-MAIN');
    final items = await admin.get<List<dynamic>>('/api/items');
    final item = items.cast<Map<String, dynamic>>().firstWhere((i) => i['code'] == 'TEST-FIFO-1');
    final settings = await admin.get<List<dynamic>>('/api/item-branch-settings');
    final price = (settings.cast<Map<String, dynamic>>().firstWhere((s) => s['itemId'] == item['id'] && s['branchId'] == 'br-hq')['sellingPrice'] as num)
        .toDouble();
    final vehicles = await admin.get<List<dynamic>>('/api/vehicles');
    final truck = vehicles.cast<Map<String, dynamic>>().firstWhere((v) => v['code'] == 'E2E55464');
    final customers = await admin.get<List<dynamic>>('/api/customers');
    final customer = customers
        .cast<Map<String, dynamic>>()
        .firstWhere((c) => c['branchId'] == 'br-hq' && c['status'] == 'active' && c['name'] != 'Walk-in Customer');
    final methods = await admin.get<List<dynamic>>('/api/payment-methods');
    final cash = methods.cast<Map<String, dynamic>>().firstWhere((m) => m['code'] == 'CASH');
    final now = DateTime.now().toUtc().toIso8601String();

    var so = await admin.post<Map<String, dynamic>>('/api/sales-orders', {
      'branchId': 'br-hq', 'customerId': customer['id'], 'orderDate': now, 'remarks': 'Mobile route live test', 'discountPct': null,
      'createdBy': adminId,
      'lines': [{'itemId': item['id'], 'qty': 2, 'uomId': item['baseUomId'], 'unitPrice': price, 'discountPct': 0}],
    });
    if (so['status'] == 'DRAFT') so = await admin.post<Map<String, dynamic>>('/api/sales-orders/${so['id']}/submit', {'requestedBy': adminId});
    if (so['status'] == 'PENDING_APPROVAL') {
      so = await manager.post<Map<String, dynamic>>('/api/sales-orders/${so['id']}/approve', {'approverUserId': managerId});
    }
    expect(so['status'], 'POSTED');
    final trip = await admin.post<Map<String, dynamic>>('/api/trips', {
      'branchId': 'br-hq', 'vehicleId': truck['id'], 'routeId': null, 'sourceWarehouseId': main['id'], 'driverUserId': driver.userId,
      'driverEmployeeId': null, 'helperNames': 'Mobile live test', 'tripDate': now, 'remarks': 'Mobile route live test',
      'salesOrderIds': [so['id']], 'extraLines': [{'itemId': item['id'], 'qty': 3}], 'createdBy': adminId,
    });
    final tripId = trip['id'] as String;
    await admin.post<dynamic>('/api/trips/$tripId/submit', {'requestedBy': adminId});
    await manager.post<dynamic>('/api/trips/$tripId/approve-load', {'approverUserId': managerId, 'comments': null});
    // ignore: avoid_print
    print('trip ${trip['tripNo']} planned (SO ${so['soNo']} x2 + 3 extra), load approved');

    // ---- handheld: download and accept the load
    expect(await route.download(driver.userId), greaterThan(0));
    var view = (await route.trip(tripId))!;
    expect(view.status, TripStatus.loaded);
    final discrepancies = await route.acceptLoad(driver.userId, tripId, {item['id'] as String: 5});
    expect(discrepancies, isEmpty);
    view = (await route.trip(tripId))!;
    expect(view.onTheRoad, isTrue);
    final firstNumber = view.series.nextFormatted;

    // ---- offline work: invoice (1 of 2 ordered, 1 refused for a reason, 1 van sale), a void, a return
    final order = view.latest.salesOrders.single;
    SaleLineDraft line(double q, {String? soLine}) => SaleLineDraft(
        itemId: item['id'] as String, code: item['code'] as String, name: item['name'] as String, uomId: item['baseUomId'] as String,
        vatType: parseVatType(item['vatType'] as String?), qty: q, unitPrice: price, salesOrderLineId: soLine);
    final draft = SaleDraft(
      tripId: tripId,
      customerId: customer['id'] as String,
      customerName: customer['name'] as String,
      salesOrderId: order.id,
      lines: [line(1, soLine: order.lines.single.salesOrderLineId), line(1)],
      refusals: [RefusalDraft(salesOrderLineId: order.lines.single.salesOrderLineId, itemId: item['id'] as String, qty: 1, reasonCode: 'NO_PAYMENT')],
      tenders: [TenderDraft(paymentMethodId: cash['id'] as String, code: 'CASH', name: 'Cash', amount: price * 2 + 20)],
      receivedByName: 'Mobile live test',
    );
    final sale = await route.recordSale(driver.userId, draft);
    expect(sale.invoiceNumber, firstNumber);
    expect(sale.data['change'], closeTo(20, 0.0001));
    final voided = await route.voidNextNumber(driver.userId, tripId, 'Spoiled printout');
    await route.recordReturn(driver.userId, tripId, customer['id'] as String, customer['name'] as String, [line(1)], {}, 'Wrong size');
    view = (await route.trip(tripId))!;
    expect(view.ledger.onTruck(item['id'] as String), 4, reason: '5 − 1 delivered − 1 sold + 1 returned');

    // ---- sync
    final report = await push.pushAll(userId: driver.userId);
    expect(report.failed + report.needsReview, 0, reason: (await outbox.list(statuses: {OutboxStatus.failed, OutboxStatus.needsReview})).map((e) => '${e.title}: ${e.lastError}').join('; '));
    expect((await outbox.get(sale.outboxId!))!.status, OutboxStatus.synced);
    expect((await outbox.get(voided.outboxId!))!.status, OutboxStatus.synced);

    // ZARI now agrees with the device's ledger.
    await route.download(driver.userId);
    view = (await route.trip(tripId))!;
    final serverLine = view.latest.trip.lines.single;
    final local = view.ledger.items[item['id']]!;
    expect(serverLine.qtyDelivered, local.delivered);
    expect(serverLine.qtyVanSold, local.vanSold);
    expect(serverLine.qtyRefused, local.refused);
    expect(serverLine.qtyReturnedGood, local.returnedGood);
    expect(serverLine.qtyExpectedOnTruck, local.onTruck);
    expect(view.latest.trip.cashExpected, closeTo(view.ledger.cashExpected, 0.0001));
    expect(view.latest.nextInvoiceNumber, view.series.nextFormatted, reason: 'the void used up a number on both sides');
    expect(view.latest.recordedInvoiceNumbers, containsAll([firstNumber, voided.invoiceNumber]));

    // ---- end of trip: count what's left, hand in the cash; then the manager closes it
    await route.endTrip(driver.userId, tripId, {for (final i in view.ledger.countSheet) i.itemId: i.onTruck}, view.ledger.cashExpected);
    final endReport = await push.pushAll(userId: driver.userId);
    expect(endReport.failed + endReport.needsReview, 0);
    final ended = await admin.get<Map<String, dynamic>>('/api/trips/$tripId');
    expect(ended['status'], 'PENDING_CLOSE_APPROVAL');
    final closed = await manager.post<Map<String, dynamic>>(
        '/api/trips/$tripId/approve-close', {'approverUserId': managerId, 'comments': 'Mobile live test', 'shortageSettlement': null});
    expect(closed['status'], 'CLOSED');
    expect((closed['shortageAmount'] as num).toDouble(), 0, reason: 'count and cash matched exactly');

    await route.download(driver.userId);
    expect(await route.trip(tripId), isNull, reason: 'a closed trip drops off the device');
    // ignore: avoid_print
    print('trip ${trip['tripNo']}: invoice $firstNumber, void ${voided.invoiceNumber}, synced, ended and closed');
    await db.db.close();
  }, skip: url == null ? 'Set ZARI_LIVE_URL to run against a live API' : false);
}
