import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The on-device SQLite store. Two halves:
///  * a read cache of ZARI master data (items, prices, stock, customers, ...)
///    refreshed by MasterDataSync — always safe to wipe and re-download;
///  * the `outbox` — documents captured on the device that haven't reached
///    ZARI yet. This is the only data that exists nowhere else, so nothing
///    here may ever be dropped silently.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _version = 2;

  static Future<AppDatabase> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'zari_mobile.db');
    final db = await f.openDatabase(dbPath,
        options: OpenDatabaseOptions(
          version: _version,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, version) async {
            await _createV1(db);
            await _upgradeToV2(db);
          },
          onUpgrade: (db, from, to) async {
            if (from < 2) await _upgradeToV2(db);
          },
        ));
    return AppDatabase._(db);
  }

  static Future<void> _createV1(Database db) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY,
        code TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        category_id TEXT,
        base_uom_id TEXT NOT NULL,
        item_type TEXT,
        vat_type TEXT NOT NULL,
        status TEXT NOT NULL,
        is_sold INTEGER NOT NULL,
        is_stocked INTEGER NOT NULL,
        is_serialized INTEGER NOT NULL,
        is_batch_tracked INTEGER NOT NULL,
        allow_negative_stock INTEGER NOT NULL
      )''');
    batch.execute('CREATE INDEX ix_items_code ON items(code)');
    batch.execute('CREATE INDEX ix_items_name ON items(name)');

    batch.execute('''
      CREATE TABLE item_branch_settings (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        default_warehouse_id TEXT,
        selling_price REAL,
        status TEXT NOT NULL
      )''');
    batch.execute('CREATE INDEX ix_ibs_item_branch ON item_branch_settings(item_id, branch_id)');

    batch.execute('''
      CREATE TABLE stock_balances (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        warehouse_id TEXT NOT NULL,
        batch_no TEXT,
        qty_on_hand REAL NOT NULL,
        avg_unit_cost REAL NOT NULL,
        last_movement_date TEXT
      )''');
    batch.execute('CREATE INDEX ix_stock_item ON stock_balances(item_id)');
    batch.execute('CREATE INDEX ix_stock_wh ON stock_balances(warehouse_id)');

    // Small reference lists, one generic table: branches, warehouses, uoms,
    // customers, payment methods, POS terminals, statutory discount types,
    // adjustment reasons, company settings.
    batch.execute('''
      CREATE TABLE ref_data (
        entity TEXT NOT NULL,
        id TEXT NOT NULL,
        code TEXT,
        name TEXT,
        branch_id TEXT,
        status TEXT,
        json TEXT NOT NULL,
        PRIMARY KEY (entity, id)
      )''');
    batch.execute('CREATE INDEX ix_ref_entity_name ON ref_data(entity, name)');

    batch.execute('''
      CREATE TABLE outbox (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        method TEXT NOT NULL,
        path TEXT NOT NULL,
        body TEXT NOT NULL,
        follow_up_path TEXT,
        follow_up_body TEXT,
        meta TEXT,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        server_id TEXT,
        server_ref TEXT,
        server_response TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced_at TEXT
      )''');
    batch.execute('CREATE INDEX ix_outbox_status ON outbox(status, created_at)');

    batch.execute('CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');

    await batch.commit(noResult: true);
  }

  /// v2 — Route Sales (rolling trucks). `idempotent` marks outbox rows whose endpoint is safe to resend
  /// (route sales are keyed by the invoice number; returns/collections/refusals by a client id), so an
  /// ambiguous send goes back to pending instead of needing review.
  static Future<void> _upgradeToV2(Database db) async {
    final batch = db.batch();
    batch.execute('ALTER TABLE outbox ADD COLUMN idempotent INTEGER NOT NULL DEFAULT 0');

    // The driver's trips as last downloaded (GET /api/trips/mine). `baseline` is the trip as it stood when the
    // device started tracking it — everything since is in route_events, so truck stock, order balances and
    // expected cash stay exact offline (only this trip's driver can record against it).
    batch.execute('''
      CREATE TABLE route_trips (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        status TEXT NOT NULL,
        bundle TEXT NOT NULL,
        baseline TEXT,
        downloaded_at TEXT NOT NULL
      )''');

    // The handheld's invoice series. The next number only ever moves forward: a number is claimed in the same
    // transaction that records the sale/void, and a fresh download can only raise it, never lower it.
    batch.execute('''
      CREATE TABLE route_series (
        terminal_id TEXT PRIMARY KEY,
        prefix TEXT NOT NULL,
        padding INTEGER NOT NULL,
        next_number INTEGER NOT NULL
      )''');

    // What the driver did on this device: sale, void, refusal, return, collection, end.
    batch.execute('''
      CREATE TABLE route_events (
        id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        invoice_number TEXT,
        data TEXT NOT NULL,
        outbox_id TEXT,
        created_at TEXT NOT NULL
      )''');
    batch.execute('CREATE INDEX ix_route_events_trip ON route_events(trip_id, created_at)');
    await batch.commit(noResult: true);
  }

  Future<String?> getMeta(String key) async {
    final rows = await db.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) =>
      db.insert('sync_meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Wipes the master-data cache (never the outbox) — used when a different
  /// user signs in on a shared device.
  Future<void> clearCache() async {
    await db.transaction((txn) async {
      for (final table in ['items', 'item_branch_settings', 'stock_balances', 'ref_data']) {
        await txn.delete(table);
      }
      await txn.delete('sync_meta', where: "key LIKE 'pull.%'");
    });
  }
}
