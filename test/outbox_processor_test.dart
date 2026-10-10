import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zari_mobile/core/token_store.dart';
import 'package:zari_mobile/features/sync/outbox.dart';
import 'package:zari_mobile/features/sync/outbox_processor.dart';

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
