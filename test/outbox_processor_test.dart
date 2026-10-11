import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zari_mobile/core/token_store.dart';
import 'package:zari_mobile/features/sync/outbox.dart';
import 'package:zari_mobile/features/sync/outbox_processor.dart';
import 'package:zari_mobile/features/inventory/stock_documents.dart';
import 'package:zari_mobile/features/masterdata/models.dart';
import 'package:zari_mobile/features/sales/pos_service.dart';
import 'package:zari_mobile/features/sales/sales_calculator.dart';
import 'package:zari_mobile/features/sales/sales_order_service.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  late OutboxRepository outbox;
  late OutboxProcessor processor;

  setUp(() async {
    env = await TestEnv.create();
    outbox = OutboxRepository(env.db);
    processor = OutboxProcessor(env.api, outbox);
    await env.tokens.save(const AuthTokens(accessToken: 'jwt-1', refreshToken: 'rt-1', userId: 'u1'));
  });

  tearDown(() => env.close());

  Future<OutboxEntry> queue(String path, {String? followUp, String userId = 'u1'}) => outbox.enqueue(
        userId: userId,
        branchId: 'BR1',
        type: OutboxType.salesOrder,
        title: 't',
        path: path,
        body: {'x': 1},
        followUpPath: followUp,
        followUpBody: followUp == null ? null : {'requestedBy': userId},
      );

  test('success stores the ZARI id and document number', () async {
    env.adapter.handler = (req, _) => Json({'id': 'so-1', 'soNo': 'SO-0001', 'status': 'DRAFT'});
    final e = await queue('/api/sales-orders');

    final report = await processor.pushAll(userId: 'u1');

    final after = (await outbox.get(e.id))!;
    expect(report.synced, 1);
    expect(after.status, OutboxStatus.synced);
    expect(after.serverId, 'so-1');
    expect(after.serverRef, 'SO-0001');
    expect(env.adapter.calls.single, 'POST /api/sales-orders');
  });

  test('offline keeps the entry pending and stops the run', () async {
    env.adapter.handler = (_, __) => Fail(DioExceptionType.connectionError);
    final a = await queue('/api/a');
    final b = await queue('/api/b');

    final report = await processor.pushAll(userId: 'u1');

    expect(report.stoppedBy, PushStop.offline);
    expect((await outbox.get(a.id))!.status, OutboxStatus.pending);
    expect((await outbox.get(b.id))!.status, OutboxStatus.pending);
    expect(env.adapter.calls, ['POST /api/a'], reason: 'no point hammering the rest of the queue while offline');
  });

  test('a timeout after sending goes to review, never back to pending', () async {
    env.adapter.handler = (req, _) =>
        req.path == '/api/a' ? Fail(DioExceptionType.receiveTimeout) : Json({'id': 'b-1', 'soNo': 'SO-2'});
    final a = await queue('/api/a');
    final b = await queue('/api/b');

    final report = await processor.pushAll(userId: 'u1');

    expect((await outbox.get(a.id))!.status, OutboxStatus.needsReview);
    expect((await outbox.get(b.id))!.status, OutboxStatus.synced, reason: 'independent documents keep flowing');
    expect(report.needsReview, 1);

    // A later run must not re-send the ambiguous one.
    env.adapter.calls.clear();
    await processor.pushAll(userId: 'u1');
    expect(env.adapter.calls, isEmpty);
  });

  test('a server rejection is marked failed with the ProblemDetails message', () async {
    env.adapter.handler = (_, __) => Json(problem('This POS terminal is not active.'), status: 400);
    final e = await queue('/api/pos/checkout');

    await processor.pushAll(userId: 'u1');

    final after = (await outbox.get(e.id))!;
    expect(after.status, OutboxStatus.failed);
    expect(after.lastError, 'This POS terminal is not active.');
  });

  test('validation errors dictionary is flattened', () async {
    env.adapter.handler = (_, __) => Json({
          'title': 'One or more validation errors occurred.',
          'errors': {
            'Lines': ['At least one item line is required.']
          }
        }, status: 400);
    final e = await queue('/api/stock-opnames');
    await processor.pushAll(userId: 'u1');
    expect((await outbox.get(e.id))!.lastError, 'At least one item line is required.');
  });

  test('when the follow-up fails, retry repeats only the follow-up', () async {
    var submitFails = true;
    env.adapter.handler = (req, _) {
      if (req.path == '/api/sales-orders') return Json({'id': 'so-9', 'soNo': 'SO-0009', 'status': 'DRAFT'});
      if (submitFails) return Json(problem('Approver setup missing.'), status: 400);
      return Json({'id': 'so-9', 'status': 'PENDING_APPROVAL'});
    };
    final e = await queue('/api/sales-orders', followUp: '/api/sales-orders/{id}/submit');

    await processor.pushAll(userId: 'u1');
    var after = (await outbox.get(e.id))!;
    expect(after.status, OutboxStatus.failed);
    expect(after.serverId, 'so-9');
    expect(after.lastError, contains('SO-0009'));

    submitFails = false;
    env.adapter.calls.clear();
    await outbox.markPending(e.id);
    await processor.pushAll(userId: 'u1');

    after = (await outbox.get(e.id))!;
    expect(after.status, OutboxStatus.synced);
    expect(env.adapter.calls, ['POST /api/sales-orders/so-9/submit'], reason: 'the create must never be repeated');
  });

  test('follow-up is skipped when ZARI quick-posted the document', () async {
    env.adapter.handler = (req, _) => Json({'id': 'so-5', 'soNo': 'SO-5', 'status': 'POSTED'});
    final e = await queue('/api/sales-orders', followUp: '/api/sales-orders/{id}/submit');

    await processor.pushAll(userId: 'u1');

    expect((await outbox.get(e.id))!.status, OutboxStatus.synced);
    expect(env.adapter.calls, ['POST /api/sales-orders']);
  });

  test('401 refreshes the token once and retries', () async {
    env.adapter.handler = (req, body) {
      if (req.path == '/api/identity/refresh') {
        expect(body, {'accessToken': 'jwt-1', 'refreshToken': 'rt-1'});
        return Json({'jwToken': 'jwt-2', 'refreshToken': 'rt-2'});
      }
      final auth = req.headers['Authorization'];
      return auth == 'Bearer jwt-2' ? Json({'id': 'x-1', 'invoiceNo': 'SI-1'}) : Json({}, status: 401);
    };
    final e = await queue('/api/pos/checkout');

    await processor.pushAll(userId: 'u1');

    expect((await outbox.get(e.id))!.status, OutboxStatus.synced);
    expect(env.tokens.current!.refreshToken, 'rt-2');
  });

  test('a rejected refresh token stops the run and keeps work pending', () async {
    var expired = false;
    env.api.onSessionExpired = () => expired = true;
    env.adapter.handler = (req, _) =>
        req.path == '/api/identity/refresh' ? Json(problem('Invalid refresh token.'), status: 400) : Json({}, status: 401);
    final e = await queue('/api/pos/checkout');

    final report = await processor.pushAll(userId: 'u1');

    expect(report.stoppedBy, PushStop.unauthorized);
    expect(expired, isTrue);
    expect((await outbox.get(e.id))!.status, OutboxStatus.pending);
  });

  test("only the signed-in user's entries are pushed", () async {
    env.adapter.handler = (_, __) => Json({'id': 'z', 'soNo': 'SO-z'});
    final mine = await queue('/api/a');
    final theirs = await queue('/api/b', userId: 'someone-else');

    await processor.pushAll(userId: 'u1');

    expect((await outbox.get(mine.id))!.status, OutboxStatus.synced);
    expect((await outbox.get(theirs.id))!.status, OutboxStatus.pending);
  });

  Future<OutboxEntry> queueIdempotent(String path, {String? followUp}) => outbox.enqueue(
        userId: 'u1',
        branchId: 'BR1',
        type: OutboxType.salesOrder,
        title: 't',
        path: path,
        body: {'clientReferenceId': 'ref-1'},
        followUpPath: followUp,
        followUpBody: followUp == null ? null : {'requestedBy': 'u1'},
        idempotent: true,
      );

  test('an idempotent create whose answer was lost goes back to pending and is resent with the same key', () async {
    var timeout = true;
    env.adapter.handler = (req, _) => timeout ? Fail(DioExceptionType.receiveTimeout) : Json({'id': 'so-1', 'soNo': 'SO-1', 'status': 'DRAFT'});
    final e = await queueIdempotent('/api/sales-orders');

    await processor.pushAll(userId: 'u1');
    expect((await outbox.get(e.id))!.status, OutboxStatus.pending, reason: 'ZARI returns the same order on a resend');

    timeout = false;
    await processor.pushAll(userId: 'u1');
    final after = (await outbox.get(e.id))!;
    expect(after.status, OutboxStatus.synced);
    expect(after.body['clientReferenceId'], 'ref-1');
    expect(env.adapter.calls, ['POST /api/sales-orders', 'POST /api/sales-orders']);
  });

  test('a retried follow-up is skipped when ZARI shows it already went through', () async {
    var submitTimesOut = true;
    env.adapter.handler = (req, _) {
      if (req.method == 'GET') return Json({'id': 'so-9', 'status': 'PENDING_APPROVAL'});
      if (req.path == '/api/sales-orders') return Json({'id': 'so-9', 'soNo': 'SO-0009', 'status': 'DRAFT'});
      return submitTimesOut ? Fail(DioExceptionType.receiveTimeout) : Json(problem('Only a DRAFT order can be submitted.'), status: 400);
    };
    final e = await queueIdempotent('/api/sales-orders', followUp: '/api/sales-orders/{id}/submit');

    await processor.pushAll(userId: 'u1');
    expect((await outbox.get(e.id))!.status, OutboxStatus.pending);

    submitTimesOut = false;
    env.adapter.calls.clear();
    await processor.pushAll(userId: 'u1');
    expect((await outbox.get(e.id))!.status, OutboxStatus.synced);
    expect(env.adapter.calls, ['GET /api/sales-orders/so-9'], reason: 'neither the create nor the submit is repeated');
  });

  test('POS sales, sales orders and stock documents carry their outbox id as the idempotency key', () async {
    const item = Item(id: 'i1', code: 'RICE', name: 'Rice', baseUomId: 'u', vatType: VatType.vatable, status: 'active',
        isSold: true, isStocked: true, isSerialized: false, isBatchTracked: false, allowNegativeStock: false);
    final line = CartLine(key: 'i1', item: item, qty: 1, unitPrice: 50, discountPct: 0, defaultWarehouseId: 'wh');
    const customer = RefRecord(RefEntity.customer, {'id': 'c1', 'name': 'Alpha'});
    const terminal = RefRecord(RefEntity.posTerminal, {'id': 't1', 'code': 'T1', 'name': 'T1'});
    const cash = RefRecord(RefEntity.paymentMethod, {'id': 'pm', 'code': 'CASH', 'name': 'Cash'});

    final entries = [
      await queuePosSale(outbox: outbox, userId: 'u1', branchId: 'BR1', terminal: terminal, customer: null, headerDiscountPct: 0,
          lines: [line], tenders: [Tender(method: cash, amount: 50)]),
      await queueSalesOrder(outbox: outbox, userId: 'u1', branchId: 'BR1', customer: customer, orderDate: DateTime.now(),
          headerDiscountPct: 0, lines: [line]),
      await queueStockDocument(outbox: outbox, mode: StockDocMode.opname, userId: 'u1', branchId: 'BR1', warehouseId: 'wh',
          warehouseName: 'Main', date: DateTime.now(), lines: [StockDocLine(item: item, systemQty: 5, unitCost: 30, countedQty: 4)]),
    ];

    for (final e in entries) {
      expect(e.body['clientReferenceId'], e.id, reason: e.type);
      expect(e.idempotent, isTrue, reason: e.type);
    }
  });

  test('entries interrupted mid-send are recovered safely', () async {
    final notCreated = await queue('/api/a');
    final created = await queue('/api/b', followUp: '/api/b/{id}/submit');
    await outbox.markSyncing(notCreated.id);
    await outbox.markSyncing(created.id);
    await outbox.markCreated(created.id, serverId: 'b-1');

    await outbox.recoverInterrupted();

    expect((await outbox.get(notCreated.id))!.status, OutboxStatus.needsReview);
    expect((await outbox.get(created.id))!.status, OutboxStatus.pending);
  });
}
