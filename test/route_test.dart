import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zari_mobile/features/masterdata/models.dart';
import 'package:zari_mobile/features/route/printing/escpos.dart';
import 'package:zari_mobile/features/route/printing/invoice_layout.dart';
import 'package:zari_mobile/features/route/route_ledger.dart';
import 'package:zari_mobile/features/route/route_models.dart';
import 'package:zari_mobile/features/route/route_service.dart';
import 'package:zari_mobile/features/sync/outbox.dart';
import 'package:zari_mobile/features/sync/outbox_processor.dart';

import 'helpers.dart';

const tripId = 'trip-1';
const terminalId = 'term-1';
const user = 'driver-1';
const rice = 'item-rice';
const sugar = 'item-sugar';
const store = 'cust-1';
const soLine = 'sol-1';

/// A trip on the road: rice 8 on the truck (5 ordered by Alpha Store + 3 extra), sugar 10 extra.
/// Alpha owes 100 on one old invoice and has a credit limit of 1,000. Next handheld number T1-000501.
Map<String, dynamic> bundleJson({String status = 'IN_TRANSIT', String next = 'T1-000501', double cash = 0}) => {
      'trip': {
        'id': tripId,
        'tripNo': 'HQ-TRP-000001',
        'branchId': 'br-1',
        'vehicleCode': 'TRK1',
        'plateNo': 'ABC 1234',
        'posTerminalId': terminalId,
        'tripDate': '2026-10-11T12:00:00Z',
        'status': status,
        'cashExpected': cash,
        'lines': [
          {
            'itemId': rice, 'itemCode': 'RICE-25', 'itemName': 'Rice 25kg', 'uomId': 'u', 'qtyLoaded': 8, 'qtyDelivered': 0,
            'qtyVanSold': 0, 'qtyRefused': 0, 'qtyReturnedGood': 0, 'qtyReturnedDamaged': 0, 'qtyExpectedOnTruck': 8,
          },
          {
            'itemId': sugar, 'itemCode': 'SUGAR-1', 'itemName': 'Sugar 1kg', 'uomId': 'u', 'qtyLoaded': 10, 'qtyDelivered': 0,
            'qtyVanSold': 0, 'qtyRefused': 0, 'qtyReturnedGood': 0, 'qtyReturnedDamaged': 0, 'qtyExpectedOnTruck': 10,
          },
        ],
      },
      'nextInvoiceNumber': next,
      'machineIdentificationNumber': 'MIN-123',
      'posPermitNumber': 'PTU-9',
      'salesOrders': [
        {
          'id': 'so-1', 'soNo': 'HQ-SO-000001', 'customerId': store, 'customerName': 'Alpha Store',
          'lines': [
            {'salesOrderLineId': soLine, 'itemId': rice, 'uomId': 'u', 'qty': 5, 'qtyRemaining': 5, 'unitPrice': 112, 'discountPct': 0}
          ],
        }
      ],
      'stops': [
        {
          'customerId': store, 'customerName': 'Alpha Store', 'sequence': 1, 'openBalance': 100, 'creditLimit': 1000,
          'tin': '123-456-789',
          'openInvoices': [
            {'salesInvoiceId': 'inv-old', 'invoiceNo': 'HQ-SINV-1', 'birOrSeriesNumber': 'OR-1', 'invoiceDate': '2026-09-01T00:00:00Z', 'balance': 100}
          ],
        }
      ],
      'recordedInvoiceNumbers': [],
      'refusalReasons': [
        {'code': 'NO_PAYMENT', 'label': "Customer can't pay"},
        {'code': 'OTHER', 'label': 'Other'},
      ],
      'invoiceHeader': {'registeredName': 'Test Cooperative', 'tin': '000-111-222', 'vatRegistrationType': 'VAT', 'branchName': 'Head Office'},
    };

SaleLineDraft riceFromOrder(double qty) => SaleLineDraft(
    itemId: rice, code: 'RICE-25', name: 'Rice 25kg', uomId: 'u', vatType: VatType.vatable, qty: qty, unitPrice: 112, salesOrderLineId: soLine);
SaleLineDraft sugarVanSale(double qty) =>
    SaleLineDraft(itemId: sugar, code: 'SUGAR-1', name: 'Sugar 1kg', uomId: 'u', vatType: VatType.vatable, qty: qty, unitPrice: 56);
TenderDraft cash(double amount) => TenderDraft(paymentMethodId: 'pm-cash', code: 'CASH', name: 'Cash', amount: amount);

SaleDraft orderSale({double rice = 5, double sugar = 2, double paid = 700, List<RefusalDraft>? refusals}) => SaleDraft(
      tripId: tripId,
      customerId: store,
      customerName: 'Alpha Store',
      salesOrderId: 'so-1',
      lines: [riceFromOrder(rice), if (sugar > 0) sugarVanSale(sugar)],
      refusals: refusals,
      tenders: [if (paid > 0) cash(paid)],
    );

void main() {
  late TestEnv env;
  late OutboxRepository outbox;
  late RouteService route;

  setUp(() async {
    env = await TestEnv.create();
    outbox = OutboxRepository(env.db);
    route = RouteService(env.db, outbox, env.api);
    await route.saveBundles(user, [bundleJson()]);
  });
  tearDown(() => env.close());

  group('invoice series', () {
    test('parses and formats the handheld number', () {
      final s = InvoiceSeries.parse('E2E55464-000004');
      expect(s.prefix, 'E2E55464-');
      expect(s.next, 4);
      expect(s.format(12), 'E2E55464-000012');
    });

    test('a new download never moves the series backwards', () async {
      await route.recordSale(user, orderSale());
      expect((await route.trip(tripId))!.series.nextFormatted, 'T1-000502');
      // ZARI hasn't seen 501 yet, so it still says 501 is next.
      await route.saveBundles(user, [bundleJson(next: 'T1-000501')]);
      expect((await route.trip(tripId))!.series.nextFormatted, 'T1-000502');
      // ...but a higher number from ZARI wins.
      await route.saveBundles(user, [bundleJson(next: 'T1-000510')]);
      expect((await route.trip(tripId))!.series.nextFormatted, 'T1-000510');
    });
  });

  group('sale', () {
    test('records the next number, an idempotent outbox row and updates the ledger', () async {
      final sale = await route.recordSale(user, orderSale());
      final second = await route.recordSale(user, SaleDraft(
          tripId: tripId, customerId: store, customerName: 'Alpha Store', lines: [sugarVanSale(1)], tenders: [cash(56)]));

      expect(sale.invoiceNumber, 'T1-000501');
      expect(second.invoiceNumber, 'T1-000502');
      final entry = (await outbox.get(sale.outboxId!))!;
      expect(entry.type, OutboxType.routeSale);
      expect(entry.idempotent, isTrue);
      expect(entry.body['birOrSeriesNumber'], 'T1-000501');
      expect(entry.path, '/api/trips/$tripId/route-sales');

      final view = (await route.trip(tripId))!;
      expect(view.ledger.onTruck(rice), 3);
      expect(view.ledger.onTruck(sugar), 7);
      expect(view.ledger.orderLineOpen(soLine), 0);
      expect(sale.data['total'], 672);
      expect(sale.data['change'], 28);
      expect(view.ledger.cashExpected, 672 + 56);
      expect(view.ledger.invoiceCount, 2);
    });

    test('a partial delivery needs a reason for the rest', () async {
      final view = (await route.trip(tripId))!;
      final short = checkSale(view.ledger, orderSale(rice: 3, paid: 500), onTheRoad: true);
      expect(short.errors.single, contains('2 not delivered'));

      final withReason = checkSale(
          view.ledger,
          orderSale(rice: 3, paid: 500, refusals: [RefusalDraft(salesOrderLineId: soLine, itemId: rice, qty: 2, reasonCode: 'NO_PAYMENT')]),
          onTheRoad: true);
      expect(withReason.ok, isTrue, reason: withReason.errors.join());

      final otherNoNotes = checkSale(
          view.ledger,
          orderSale(rice: 3, paid: 500, refusals: [RefusalDraft(salesOrderLineId: soLine, itemId: rice, qty: 2, reasonCode: 'OTHER')]),
          onTheRoad: true);
      expect(otherNoNotes.errors.single, contains('Other'));
    });

    test('refuses more than is on the truck, a charge over the credit limit, and change from a non-cash tender', () async {
      final view = (await route.trip(tripId))!;
      expect(checkSale(view.ledger, orderSale(sugar: 11), onTheRoad: true).errors.single, contains('only 10 on the truck'));
      // 672 on account + 100 already owed is within 1,000; push it over with a bigger order.
      expect(checkSale(view.ledger, orderSale(paid: 0), onTheRoad: true).ok, isTrue);
      final big = SaleDraft(tripId: tripId, customerId: store, customerName: 'Alpha Store', lines: [sugarVanSale(10), riceFromOrder(0)])
        ..lines.add(SaleLineDraft(itemId: rice, code: 'RICE-25', name: 'Rice', uomId: 'u', vatType: VatType.vatable, qty: 4, unitPrice: 112)); // 560 + 448 + 100 owed > 1,000
      expect(checkSale(view.ledger, big, onTheRoad: true).errors.single, contains('credit limit'));
      final gcash = SaleDraft(tripId: tripId, customerId: store, customerName: 'Alpha Store', lines: [sugarVanSale(1)], tenders: [
        TenderDraft(paymentMethodId: 'pm-g', code: 'GCASH', name: 'GCash', amount: 100, referenceNo: 'R1'),
      ]);
      expect(checkSale(view.ledger, gcash, onTheRoad: true).errors.single, contains('Change'));
      expect(checkSale(view.ledger, orderSale(), onTheRoad: false).errors.first, contains('on the road'));
    });

    test('voiding an unsynced invoice turns its queued sale into a void in the same queue position', () async {
      final sale = await route.recordSale(user, orderSale());
      final next = await route.recordSale(user, SaleDraft(
          tripId: tripId, customerId: store, customerName: 'Alpha Store', lines: [sugarVanSale(1)], tenders: [cash(56)]));
      final before = (await outbox.get(sale.outboxId!))!;

      await route.voidSale(sale, 'Printer jammed');

      final after = (await outbox.get(sale.outboxId!))!;
      expect(after.type, OutboxType.routeVoid);
      expect(after.body, {'birOrSeriesNumber': 'T1-000501', 'reason': 'Printer jammed'});
      expect(after.createdAt, before.createdAt, reason: 'the void must still reach ZARI before 502');
      final queue = await outbox.list(statuses: {OutboxStatus.pending});
      expect(queue.map((e) => e.id).toList(), [sale.outboxId, next.outboxId]);
      final view = (await route.trip(tripId))!;
      expect(view.ledger.onTruck(rice), 8, reason: 'the voided sale no longer takes stock');
      expect(view.ledger.voidCount, 1);
    });

    test('a synced invoice cannot be voided on the device', () async {
      final sale = await route.recordSale(user, orderSale());
      await outbox.markSynced(sale.outboxId!);
      expect(() => route.voidSale(sale, 'x'), throwsStateError);
    });
  });

  group('refusal, return, collection, end', () {
    test('a whole-stop refusal closes the order line on this trip without using a number', () async {
      await route.recordRefusal(user, tripId, store, 'Alpha Store', 'so-1',
          [RefusalDraft(salesOrderLineId: soLine, itemId: rice, qty: 5, reasonCode: 'NO_PAYMENT')]);
      final view = (await route.trip(tripId))!;
      expect(view.ledger.orderLineOpen(soLine), 0);
      expect(view.ledger.onTruck(rice), 8);
      expect(view.series.nextFormatted, 'T1-000501');
      final entry = (await outbox.list(type: OutboxType.routeRefusal)).single;
      expect(entry.idempotent, isTrue);
      expect(entry.body['clientRef'], isNotEmpty);
    });

    test('good returns go back on the truck, damaged ones do not', () async {
      await route.recordReturn(user, tripId, store, 'Alpha Store', [sugarVanSale(2), riceFromOrder(1)], {rice: true}, 'Expired');
      final view = (await route.trip(tripId))!;
      expect(view.ledger.onTruck(sugar), 12);
      expect(view.ledger.onTruck(rice), 8);
      expect(view.ledger.items[rice]!.returnedDamaged, 1);
    });

    test('collections are allocated oldest-first to invoices open at download, and never beyond them', () async {
      await route.recordCollection(user, tripId, store, 'Alpha Store', cash(60));
      var view = (await route.trip(tripId))!;
      expect(view.ledger.customerOwes(store), 40);
      expect(view.ledger.cashExpected, 60);
      expect(route.collectionAllocations(view, store, 1000).single['amount'], 40);
      expect(() => route.recordCollection(user, tripId, store, 'Alpha Store', cash(50)), throwsStateError);
      view = (await route.trip(tripId))!;
      expect(view.ledger.customerOwes(store), 40);
    });

    test('a charge issued on this trip is collected by its invoice number, after the older invoices', () async {
      final sale = await route.recordSale(user, orderSale(paid: 0)); // T1-000501: 672 on account
      expect(sale.data['charged'], 672);

      final collection = await route.recordCollection(user, tripId, store, 'Alpha Store', cash(700));

      final allocations = (await outbox.get(collection.outboxId!))!.body['allocations'] as List;
      expect(allocations.map((a) => {...a as Map}..remove('label')).toList(), [
        {'salesInvoiceId': 'inv-old', 'amount': 100},
        {'invoiceNumber': 'T1-000501', 'amount': 600},
      ]);
      final view = (await route.trip(tripId))!;
      expect(view.ledger.customerOwes(store), 72);
      expect(route.collectionAllocations(view, store, 1000).single, containsPair('invoiceNumber', 'T1-000501'));
      expect(route.collectionAllocations(view, store, 1000).single['amount'], 72);
      expect(() => route.voidSale(sale, 'Wrong customer'), throwsStateError, reason: 'ZARI would refuse the collection');
    });

    test('ending needs every item counted and then the trip counts as ended on the device', () async {
      expect(() => route.endTrip(user, tripId, {rice: 8}, 0), throwsStateError);
      await route.endTrip(user, tripId, {rice: 8, sugar: 10}, 0);
      final view = (await route.trip(tripId))!;
      expect(view.onTheRoad, isFalse);
      expect(view.status, TripStatus.pendingClose);
      expect(() => route.recordSale(user, orderSale()), throwsStateError);
    });
  });

  group('sync', () {
    test('an ambiguous route sale goes back to pending (safe to resend), not to review', () async {
      final sale = await route.recordSale(user, orderSale());
      env.adapter.handler = (_, __) => Fail(DioExceptionType.receiveTimeout);
      final report = await OutboxProcessor(env.api, outbox).pushAll(userId: user);
      expect(report.needsReview, 0);
      expect((await outbox.get(sale.outboxId!))!.status, OutboxStatus.pending);
    });

    test('a rejected invoice holds back the trip\'s later invoices and the end of trip, but not its returns', () async {
      final first = await route.recordSale(user, orderSale());
      final second = await route.recordSale(user, SaleDraft(
          tripId: tripId, customerId: store, customerName: 'Alpha Store', lines: [sugarVanSale(1)], tenders: [cash(56)]));
      await route.recordReturn(user, tripId, store, 'Alpha Store', [sugarVanSale(1)], {}, null);
      await route.endTrip(user, tripId, {rice: 3, sugar: 8}, 0);
      env.adapter.handler = (req, _) => req.uri.path.endsWith('/route-sales')
          ? Json(problem('Customer is blocked.'), status: 400)
          : Json('return-id-1');

      await OutboxProcessor(env.api, outbox).pushAll(userId: user);

      expect((await outbox.get(first.outboxId!))!.status, OutboxStatus.failed);
      expect((await outbox.get(second.outboxId!))!.status, OutboxStatus.pending, reason: 'would be out of sequence');
      final ret = (await outbox.list(type: OutboxType.routeReturn)).single;
      expect(ret.status, OutboxStatus.synced);
      expect(ret.serverId, 'return-id-1', reason: 'a bare id answer is understood');
      expect((await outbox.list(type: OutboxType.routeEnd)).single.status, OutboxStatus.pending);
      expect(env.adapter.calls.where((c) => c.endsWith('/route-sales')).length, 1);
    });

    test('a rejected printed invoice is voided from Sync & Queue, releasing the invoices behind it', () async {
      final first = await route.recordSale(user, orderSale());
      final second = await route.recordSale(user, SaleDraft(
          tripId: tripId, customerId: store, customerName: 'Alpha Store', lines: [sugarVanSale(1)], tenders: [cash(56)]));
      env.adapter.handler = (req, _) => Json(problem('Customer is blocked.'), status: 400);
      await OutboxProcessor(env.api, outbox).pushAll(userId: user);
      final failed = (await outbox.get(first.outboxId!))!;
      expect(failed.status, OutboxStatus.failed);
      expect(() => route.discardRouteEntry(failed), throwsStateError, reason: 'an invoice number cannot just disappear');

      await route.voidRejectedSale(failed, 'Rejected by ZARI: customer blocked');
      env.adapter.handler = (req, _) => req.uri.path.endsWith('/void')
          ? Json({'id': 'rs-void', 'status': 'VOID', 'birOrSeriesNumber': 'T1-000501'})
          : Json({'id': 'rs-2', 'status': 'COMPLETED', 'birOrSeriesNumber': 'T1-000502'});
      await OutboxProcessor(env.api, outbox).pushAll(userId: user);

      expect((await outbox.get(first.outboxId!))!.type, OutboxType.routeVoid);
      expect((await outbox.get(first.outboxId!))!.status, OutboxStatus.synced);
      expect((await outbox.get(second.outboxId!))!.status, OutboxStatus.synced);
      expect(env.adapter.calls.where((c) => c.contains('/route-sales')).toList(),
          ['POST /api/trips/$tripId/route-sales', 'POST /api/trips/$tripId/route-sales/void', 'POST /api/trips/$tripId/route-sales']);
    });

    test('discarding a rejected return also takes it out of the ledger', () async {
      await route.recordReturn(user, tripId, store, 'Alpha Store', [sugarVanSale(2)], {}, null);
      final entry = (await outbox.list(type: OutboxType.routeReturn)).single;
      await route.discardRouteEntry(entry);
      expect((await route.trip(tripId))!.ledger.onTruck(sugar), 10);
      expect(await outbox.list(type: OutboxType.routeReturn), isEmpty);
    });

    test('in-progress conflict on a route sale is retried later', () async {
      final sale = await route.recordSale(user, orderSale());
      env.adapter.handler = (_, __) => Json({...problem('Being recorded'), 'errorCode': 'RouteSale.InProgress'}, status: 409);
      await OutboxProcessor(env.api, outbox).pushAll(userId: user);
      expect((await outbox.get(sale.outboxId!))!.status, OutboxStatus.pending);
    });
  });

  group('printing', () {
    test('the invoice carries the BIR essentials and fits the paper', () async {
      final sale = await route.recordSale(user, orderSale(rice: 5, sugar: 0, paid: 0));
      final view = (await route.trip(tripId))!;
      final lines = invoiceLines(view.latest, sale, width: 32);
      final text = lines.map((l) => l.text).join('\n');
      expect(text, contains('Test Cooperative'));
      expect(text, contains('VAT REG TIN: 000-111-222'));
      expect(text, contains('SALES INVOICE'));
      expect(text, contains('T1-000501'));
      expect(text, contains('Alpha Store'));
      expect(text, contains('TIN: 123-456-789'));
      expect(text, contains('560.00'));
      expect(text, contains('Charged to account'));
      expect(text, contains('MIN: MIN-123'));
      expect(text, contains('PTU No.: PTU-9'));
      for (final l in lines) {
        expect(l.text.length, lessThanOrEqualTo(l.big ? 16 : 32), reason: '"${l.text}" is too wide');
      }
      expect(invoiceLines(view.latest, sale, width: 32, reprint: true).first.text, contains('REPRINT'));
    });

    test('ESC/POS output starts with init and spells out the peso sign', () {
      final bytes = EscPos.render(const [PrintLine('Total ₱5.00', bold: true)]);
      expect(bytes.take(2), [0x1B, 0x40]);
      expect(latin1.decode(bytes, allowInvalid: true), contains('Total P5.00'));
      expect(bytes.sublist(bytes.length - 4), [0x1D, 0x56, 0x42, 0x00]);
      expect(Cols.row('Total', '1,234.00', 20), 'Total       1,234.00');
      expect(Cols.wrap('Rice premium long name here', 10), ['Rice', 'premium', 'long name', 'here']);
    });
  });

  test('the ledger replays events on the baseline', () {
    final baseline = TripBundle.fromJson(bundleJson(cash: 50));
    final ledger = TripLedger.compute(baseline, [
      RouteEvent(id: 'e1', tripId: tripId, kind: RouteEventKind.sale, createdAt: DateTime.now(), data: {
        'customerId': store, 'total': 112.0, 'applied': 100.0, 'cashKept': 100.0,
        'lines': [{'itemId': rice, 'qty': 1, 'salesOrderLineId': soLine}],
      }),
    ]);
    expect(ledger.onTruck(rice), 7);
    expect(ledger.cashExpected, 150);
    expect(ledger.customerOwes(store), 112, reason: '100 owed before + 12 charged');
    expect(ledger.orderLineOpen(soLine), 4);
  });
}
