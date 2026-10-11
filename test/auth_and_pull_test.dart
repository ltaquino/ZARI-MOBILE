import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zari_mobile/features/auth/auth_repository.dart';
import 'package:zari_mobile/features/auth/password_verifier.dart';
import 'package:zari_mobile/features/auth/session.dart';
import 'package:zari_mobile/features/masterdata/master_data_repository.dart';
import 'package:zari_mobile/features/masterdata/master_data_sync.dart';
import 'package:zari_mobile/features/masterdata/models.dart';
import 'package:zari_mobile/features/sync/outbox.dart';

import 'helpers.dart';

FakeReply zariServer(RequestOptions req, Map<String, dynamic>? body) {
  switch (req.path) {
    case '/api/identity/login':
      if (body!['password'] != 'zari123') return Json(problem('Invalid email or password.'), status: 400);
      return Json({'id': 'u1', 'email': 'staff.hq@zari.coop', 'jwToken': 'jwt', 'refreshToken': 'rt', 'roles': ['Staff']});
    case '/api/users/u1':
      return Json({'id': 'u1', 'email': 'staff.hq@zari.coop', 'firstName': 'Hq', 'lastName': 'Staff', 'branchIds': ['HQ'], 'roleNames': ['Staff']});
    case '/api/users/u1/permissions':
      return Json([
        {'formCode': 'POS_MODE', 'canView': true, 'canCreate': true},
        {'formCode': 'ITEMS', 'canView': true},
      ]);
  }
  return Json({}, status: 404);
}

void main() {
  late TestEnv env;
  late AuthRepository auth;

  setUp(() async {
    env = await TestEnv.create(zariServer);
    auth = AuthRepository(api: env.api, tokens: env.tokens, kv: env.kv);
  });

  tearDown(() => env.close());

  group('auth', () {
    test('online sign-in caches profile, permissions and an offline verifier', () async {
      final r = await auth.login('Staff.HQ@zari.coop ', 'zari123');
      expect(r.offline, isFalse);
      expect(r.session.branchIds, ['HQ']);
      expect(r.session.can(Forms.posMode, FormAction.create), isTrue);
      expect(r.session.can(Forms.salesOrders, FormAction.create), isFalse);
      expect(env.tokens.current!.accessToken, 'jwt');
      expect(env.kv.values.values.any((v) => v.contains('zari123')), isFalse, reason: 'password must never be stored');
    });

    test('wrong password online is rejected', () async {
      expect(() => auth.login('staff.hq@zari.coop', 'nope'), throwsA(isA<AuthFailure>()));
    });

    test('offline sign-in works after one online sign-in, and checks the password', () async {
      await auth.login('staff.hq@zari.coop', 'zari123');
      await auth.logout();
      env.adapter.handler = (_, __) => Fail(DioExceptionType.connectionError);

      final r = await auth.login('staff.hq@zari.coop', 'zari123');
      expect(r.offline, isTrue);
      expect(r.session.userId, 'u1');
      expect(() => auth.login('staff.hq@zari.coop', 'wrong'), throwsA(isA<AuthFailure>()));
    });

    test('offline sign-in for an account never seen on this device is refused', () async {
      env.adapter.handler = (_, __) => Fail(DioExceptionType.connectionError);
      expect(() => auth.login('new@zari.coop', 'x'), throwsA(isA<AuthFailure>()));
    });

    test('restore resumes the session until sign-out', () async {
      await auth.login('staff.hq@zari.coop', 'zari123');
      expect((await auth.restore())?.userId, 'u1');
      await auth.logout();
      expect(await auth.restore(), isNull);
    });

    test('PBKDF2 verifier', () {
      final v = PasswordVerifier.create('u1', 's3cret', iterations: 1000);
      expect(v.verify('s3cret'), isTrue);
      expect(v.verify('S3cret'), isFalse);
      expect(PasswordVerifier.fromJson(v.toJson()).verify('s3cret'), isTrue);
    });
  });

  group('master data pull', () {
    Map<String, dynamic> item(int n) => {
          'id': 'item-$n',
          'code': 'C${n.toString().padLeft(5, '0')}',
          'name': 'Item $n',
          'baseUomId': 'uom',
          'vatType': 'VATABLE',
          'status': 'active',
          'isSold': true,
          'isStocked': true,
          'isSerialized': false,
          'isBatchTracked': false,
          'allowNegativeStock': false,
        };

    test('pages the catalog, prunes deleted items, scopes to the user\'s branches, skips 403s', () async {
      const totalItems = 1203; // 3 pages of 500
      var catalog = List.generate(totalItems, item);
      env.adapter.handler = (req, _) {
        switch (req.path) {
          case '/api/items/paged':
            final page = int.parse(req.queryParameters['page'].toString());
            final size = int.parse(req.queryParameters['pageSize'].toString());
            final slice = catalog.skip((page - 1) * size).take(size).toList();
            return Json({'items': slice, 'totalCount': catalog.length, 'page': page, 'pageSize': size});
          case '/api/item-branch-settings':
            return Json([
              {'id': 's1', 'itemId': 'item-1', 'branchId': 'HQ', 'defaultWarehouseId': 'wh1', 'sellingPrice': 55.5, 'status': 'active'},
              {'id': 's2', 'itemId': 'item-1', 'branchId': 'NORTH', 'sellingPrice': 60, 'status': 'active'},
            ]);
          case '/api/stock-ledger/balances':
            return Json([
              {'id': 'b1', 'itemId': 'item-1', 'branchId': 'HQ', 'warehouseId': 'wh1', 'qtyOnHand': 12, 'avgUnitCost': 40, 'totalValue': 480},
              {'id': 'b2', 'itemId': 'item-1', 'branchId': 'NORTH', 'warehouseId': 'wh9', 'qtyOnHand': 99, 'avgUnitCost': 40, 'totalValue': 1},
            ]);
          case '/api/customers':
            return Json([
              {'id': 'c1', 'name': 'Juan Dela Cruz', 'memberNo': 'M-001', 'status': 'active', 'branchId': 'HQ'}
            ]);
          case '/api/adjustment-reasons':
            return Json(problem('You do not have permission.', status: 403), status: 403);
          case '/api/company':
            return Json({'name': 'Coop', 'maxUnapprovedDiscountPct': 10});
        }
        return Json([]);
      };
      final sync = MasterDataSync(env.api, env.db);
      final repo = MasterDataRepository(env.db);

      final r = await sync.pull(branchIds: {'HQ'});

      expect(r.counts['items'], totalItems);
      expect(await repo.itemCount(), totalItems);
      expect(r.skipped.keys, contains('adjustment_reason'));
      final e = (await repo.findByCode('c00001', branchId: 'HQ'))!;
      expect(e.price, 55.5);
      expect(e.onHand, 12, reason: 'NORTH stock must not leak into HQ');
      expect(e.posBlockReason, isNull);
      expect((await repo.company())!.numField('maxUnapprovedDiscountPct'), 10);
      expect((await repo.searchCustomers('M-001')).single.name, 'Juan Dela Cruz');

      // An item deleted in ZARI disappears on the next full pull.
      catalog = catalog.where((i) => i['id'] != 'item-7').toList();
      await sync.pull(branchIds: {'HQ'});
      expect(await repo.itemCount(), totalItems - 1);
    });

    test('a quick pull asks only for what changed since ZARI\'s clock at the last pull, per branch, and upserts it', () async {
      final requests = <String, Map<String, dynamic>>{};
      var delta = false;
      env.adapter.serverDate = DateTime.utc(2026, 10, 11, 8, 0, 0);
      env.adapter.handler = (req, _) {
        requests['${req.path}${delta ? ' (quick)' : ''}'] = req.queryParameters;
        switch (req.path) {
          case '/api/items/paged':
            return Json({'items': delta ? [item(9)] : [item(1), item(2)], 'totalCount': delta ? 1 : 2});
          case '/api/item-branch-settings':
            return Json(delta
                ? [{'id': 's1', 'itemId': 'item-1', 'branchId': 'HQ', 'defaultWarehouseId': 'wh1', 'sellingPrice': 60, 'status': 'active'}]
                : [
                    {'id': 's1', 'itemId': 'item-1', 'branchId': 'HQ', 'defaultWarehouseId': 'wh1', 'sellingPrice': 55, 'status': 'active'},
                    {'id': 's2', 'itemId': 'item-2', 'branchId': 'HQ', 'defaultWarehouseId': 'wh1', 'sellingPrice': 20, 'status': 'active'},
                  ]);
          case '/api/stock-ledger/balances':
            return Json(delta ? [] : [{'id': 'b1', 'itemId': 'item-1', 'branchId': 'HQ', 'warehouseId': 'wh1', 'qtyOnHand': 12, 'avgUnitCost': 40}]);
          case '/api/customers':
            return Json(delta
                ? [{'id': 'c2', 'name': 'New Member', 'memberNo': 'M-002', 'status': 'active', 'branchId': 'HQ'}]
                : [{'id': 'c1', 'name': 'Juan Dela Cruz', 'memberNo': 'M-001', 'status': 'active', 'branchId': 'HQ'}]);
          case '/api/company':
            return Json({'name': 'Coop'});
        }
        return Json([]);
      };
      final sync = MasterDataSync(env.api, env.db);
      final repo = MasterDataRepository(env.db);

      await sync.pull(branchIds: {'HQ'});
      expect(requests['/api/item-branch-settings'], {'branchId': 'HQ'});
      expect(requests['/api/customers'], isEmpty, reason: 'a full pull takes everything');

      delta = true;
      await sync.pull(branchIds: {'HQ'}, includeItems: false);

      const since = '2026-10-11T07:58:00.000Z'; // ZARI's 08:00 less the 2-minute overlap
      expect(requests['/api/item-branch-settings (quick)'], {'branchId': 'HQ', 'updatedSince': since});
      expect(requests['/api/stock-ledger/balances (quick)'], {'branchId': 'HQ', 'updatedSince': since});
      expect(requests['/api/customers (quick)'], {'updatedSince': since});
      expect(requests['/api/items/paged (quick)']!['updatedSince'], since);
      expect((await repo.findByCode('C00001', branchId: 'HQ'))!.price, 60, reason: 'the changed price is applied');
      expect((await repo.findByCode('C00002', branchId: 'HQ'))!.price, 20, reason: 'unchanged rows are kept');
      expect((await repo.findByCode('C00001', branchId: 'HQ'))!.onHand, 12, reason: 'no stock change — nothing wiped');
      expect(await repo.itemCount(), 3, reason: 'the new item is added, none pruned');
      expect((await repo.searchCustomers('M-001')).single.name, 'Juan Dela Cruz');
      expect((await repo.searchCustomers('M-002')).single.name, 'New Member');
    });

    test('a user who can\'t read company/branches gets the discount threshold and branch names from device settings', () async {
      env.adapter.handler = (req, _) {
        switch (req.path) {
          case '/api/company':
          case '/api/branches':
            return Json(problem('You do not have permission.', status: 403), status: 403);
          case '/api/device-settings':
            return Json({
              'companyName': 'Coop',
              'tradeName': null,
              'maxUnapprovedDiscountPct': 15,
              'branches': [
                {'id': 'HQ', 'code': 'HQ', 'name': 'Head Office', 'status': 'active'}
              ],
            });
          case '/api/items/paged':
            return Json({'items': [], 'totalCount': 0});
        }
        return Json([]);
      };
      final repo = MasterDataRepository(env.db);

      final r = await MasterDataSync(env.api, env.db).pull(branchIds: {'HQ'});

      expect(r.skipped.keys, isNot(contains(RefEntity.company)));
      expect(r.skipped.keys, isNot(contains(RefEntity.branch)));
      expect((await repo.company())!.numField('maxUnapprovedDiscountPct'), 15);
      expect((await repo.refList(RefEntity.branch, activeOnly: false)).single.name, 'Head Office');
    });

    test('unsynced POS sales reduce the available quantity', () async {
      final outbox = OutboxRepository(env.db);
      await outbox.enqueue(
          userId: 'u1',
          branchId: 'HQ',
          type: OutboxType.posSale,
          title: 't',
          path: '/api/pos/checkout',
          body: {
            'lines': [
              {'itemId': 'item-1', 'qty': 3}
            ]
          });
      expect(await MasterDataRepository(env.db).pendingPosQty('item-1', 'HQ'), 3);
      expect(await MasterDataRepository(env.db).pendingPosQty('item-1', 'NORTH'), 0);
    });
  });

  test('remarks stamp always fits ZARI\'s 300-char limit', () {
    final s = stampRemarks('MOB-ABCDEF12', 'x' * 500);
    expect(s.length, lessThanOrEqualTo(300));
    expect(s, startsWith('[MOB-ABCDEF12] '));
    expect(stampRemarks('MOB-1', null), '[MOB-1]');
  });

  test('RefRecord tolerates entities named by description (adjustment reasons)', () {
    const r = RefRecord(RefEntity.adjustmentReason, {'id': 'a', 'code': 'DMG', 'description': 'Damaged'});
    expect(r.name, 'Damaged');
  });
}
