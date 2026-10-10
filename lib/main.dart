import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'core/app_database.dart';
import 'core/key_value_store.dart';
import 'core/providers.dart';
import 'core/token_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop builds (handy for development) need the FFI SQLite backend;
  // Android/iOS use sqflite's native plugin.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final kv = SecureKeyValueStore();
  final config = await AppConfig.load(kv);
  final tokens = TokenStore(kv);
  final db = await AppDatabase.open();

  runApp(ProviderScope(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      appConfigProvider.overrideWithValue(config),
      tokenStoreProvider.overrideWithValue(tokens),
      databaseProvider.overrideWithValue(db),
    ],
    child: const ZariApp(),
  ));
}
