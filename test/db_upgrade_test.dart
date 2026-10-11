import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zari_mobile/core/app_database.dart';

void main() {
  test('a device on schema v2 gains the item barcode table and keeps its data', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('zari_db_');
    final path = p.join(dir.path, 'zari_mobile.db');
    try {
      // Build today's schema, then wind it back to what a v2 install has.
      var db = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
      await db.setMeta('pull.items', '2026-10-01T00:00:00Z');
      await db.db.execute('DROP TABLE item_barcodes');
      await db.db.setVersion(2);
      await db.db.close();

      db = await AppDatabase.open(factory: databaseFactoryFfi, path: path);

      expect(await db.db.getVersion(), 3);
      await db.db.insert('item_barcodes', {'barcode': '4800000000015', 'item_id': 'i1', 'pack_qty': 1});
      expect((await db.db.query('item_barcodes')).single['item_id'], 'i1');
      expect(await db.getMeta('pull.items'), '2026-10-01T00:00:00Z');
      await db.db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
