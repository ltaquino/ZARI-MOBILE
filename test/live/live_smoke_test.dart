// End-to-end check against a REAL running ZARI API — skipped unless
// ZARI_LIVE_URL is set, e.g.:
//
//   ZARI_LIVE_URL=http://localhost:5000 ZARI_LIVE_EMAIL=staff.hq@zari.coop \
//   ZARI_LIVE_PASSWORD=zari123 flutter test test/live
//
// Writes only DRAFT documents (a Sales Order and a Stock Opname) and deletes
// them again; the POS check is a payload-binding probe that ZARI rejects at
// validation, before anything is created.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zari_mobile/core/api_client.dart';
import 'package:zari_mobile/core/api_exception.dart';
import 'package:zari_mobile/core/app_database.dart';
import 'package:zari_mobile/core/key_value_store.dart';
import 'package:zari_mobile/core/token_store.dart';
import 'package:zari_mobile/features/auth/auth_repository.dart';
import 'package:zari_mobile/features/inventory/stock_documents.dart';
import 'package:zari_mobile/features/masterdata/master_data_repository.dart';
import 'package:zari_mobile/features/masterdata/master_data_sync.dart';
import 'package:zari_mobile/features/masterdata/models.dart';
import 'package:zari_mobile/features/sales/sales_calculator.dart';
import 'package:zari_mobile/features/sales/sales_order_service.dart';
import 'package:zari_mobile/features/sync/outbox.dart';
import 'package:zari_mobile/features/sync/outbox_processor.dart';

void main() {
  final url = Platform.environment['ZARI_LIVE_URL'];
  final email = Platform.environment['ZARI_LIVE_EMAIL'] ?? 'staff.hq@zari.coop';
  final password = Platform.environment['ZARI_LIVE_PASSWORD'] ?? 'zari123';
  // Encoder roles can't delete documents, so test drafts are removed as admin.
  final adminEmail = Platform.environment['ZARI_LIVE_ADMIN_EMAIL'] ?? 'admin@zari.coop';
  final adminPassword = Platform.environment['ZARI_LIVE_ADMIN_PASSWORD'] ?? 'zari123';

  test('login → download → queue → sync against a live ZARI', () async {
    sqfliteFfiInit();
    final db = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final kv = MemoryKeyValueStore();
    final tokens = TokenStore(kv);
    final api = ApiClient(baseUrl: url!, tokens: tokens);
    final auth = AuthRepository(api: api, tokens: tokens, kv: kv);
    final repo = MasterDataRepository(db);
    final outbox = OutboxRepository(db);
    final processor = OutboxProcessor(api, outbox);
    final adminTokens = TokenStore(MemoryKeyValueStore());
    final admin = ApiClient(baseUrl: url, tokens: adminTokens);
    await AuthRepository(api: admin, tokens: adminTokens, kv: MemoryKeyValueStore()).login(adminEmail, adminPassword);

    // 1. Online sign-in.
    final login = await auth.login(email, password);
    final session = login.session;
    printOnFailure('signed in as ${session.email}, branches ${session.branchIds}');
    expect(login.offline, isFalse);
    expect(session.branchIds, isNotEmpty);
    final branchId = session.branchIds.first;

    // 2. Full download.
    final sw = Stopwatch()..start();
    final pull = await MasterDataSync(api, db).pull(branchIds: session.branchIds.toSet());
    // ignore: avoid_print
    print('pull ${sw.elapsed}: ${pull.counts}  skipped: ${pull.skipped.keys.toList()}');
    expect(await repo.itemCount(), greaterThan(0));

    // 3. Offline sign-in now works for this account.
    final offlineApi = ApiClient(
        baseUrl: 'http://127.0.0.1:9', tokens: tokens, dio: Dio(BaseOptions(connectTimeout: const Duration(seconds: 2))));
    final offline = await AuthRepository(api: offlineApi, tokens: tokens, kv: kv).login(email, password);
    expect(offline.offline, isTrue);

    // 4. Sales Order (DRAFT) round trip.
    final sellable = await repo.searchItems('', branchId: branchId, sellableOnly: true, limit: 5);
    final customers = await repo.searchCustomers('');
    if (sellable.isNotEmpty && customers.isNotEmpty) {
      final so = await queueSalesOrder(
        outbox: outbox,
        userId: session.userId,
        branchId: branchId,
        customer: customers.first,
        orderDate: DateTime.now(),
        remarks: 'ZARI mobile live smoke test — safe to delete',
        headerDiscountPct: 0,
        lines: [CartLine(key: 'a', item: sellable.first.item, qty: 1, unitPrice: sellable.first.price ?? 1)],
        submitForApproval: false,
      );
      final report = await processor.pushAll(userId: session.userId);
      final after = (await outbox.get(so.id))!;
      // ignore: avoid_print
      print('sales order → ${after.status} ${after.serverRef ?? ''} ${after.lastError ?? ''}');
      expect(after.status, OutboxStatus.synced, reason: after.lastError);
      expect(report.synced, 1);
      expect((after.serverResponse!['remarks'] as String), startsWith('[${so.localRef}]'));
      await admin.delete('/api/sales-orders/${after.serverId}');
    } else {
      // ignore: avoid_print
      print('no sellable item/customer at $branchId — sales order step skipped');
    }

    // 5. Stock Opname (DRAFT) round trip.
    final warehouses = await repo.refList(RefEntity.warehouse, branchId: branchId);
    final stocked = (await repo.searchItems('', branchId: branchId, limit: 50)).where((e) => e.item.isStocked).toList();
    if (warehouses.isNotEmpty && stocked.isNotEmpty) {
      final bal = await repo.balanceAt(stocked.first.item.id, warehouses.first.id);
      final op = await queueStockDocument(
        outbox: outbox,
        mode: StockDocMode.opname,
        userId: session.userId,
        branchId: branchId,
        warehouseId: warehouses.first.id,
        warehouseName: warehouses.first.name,
        date: DateTime.now(),
        lines: [StockDocLine(item: stocked.first.item, systemQty: bal.qty < 0 ? 0 : bal.qty, unitCost: bal.avgCost)],
        remarks: 'ZARI mobile live smoke test — safe to delete',
      );
      await processor.pushAll(userId: session.userId);
      final after = (await outbox.get(op.id))!;
      // ignore: avoid_print
      print('stock opname → ${after.status} ${after.serverRef ?? ''} ${after.lastError ?? ''}');
      expect(after.status, OutboxStatus.synced, reason: after.lastError);
      await admin.delete('/api/stock-opnames/${after.serverId}');
    }

    // 6. POS checkout payload binds to CreatePosSaleCommand: with no tenders
    // ZARI's validator rejects it before the handler creates anything.
    final terminals = await repo.refList(RefEntity.posTerminal, branchId: branchId);
    if (terminals.isNotEmpty && sellable.isNotEmpty) {
      try {
        await api.post<dynamic>('/api/pos/checkout', {
          'branchId': branchId,
          'posTerminalId': terminals.first.id,
          'customerId': null,
          'invoiceDate': DateTime.now().toUtc().toIso8601String(),
          'discountPct': null,
          'costCenterId': null,
          'lines': [
            {
              'itemId': sellable.first.item.id,
              'qty': 1,
              'uomId': sellable.first.item.baseUomId,
              'unitPrice': sellable.first.price ?? 1,
              'discountPct': 0,
              'vatType': 'VATABLE',
              'statutoryDiscountTypeId': null,
              'statutoryIdNumber': null,
              'serialNo': null,
            }
          ],
          'tenders': <Object>[],
          'createdBy': session.userId,
        });
        fail('expected a validation rejection');
      } on ApiException catch (e) {
        // ignore: avoid_print
        print('pos probe → ${e.statusCode}: ${e.message}');
        expect(e.message, contains('payment method'));
      }
    }

    await db.db.close();
  }, skip: url == null ? 'set ZARI_LIVE_URL to run against a live ZARI API' : false);
}
