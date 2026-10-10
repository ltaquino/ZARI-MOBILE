import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_repository.dart';
import '../features/masterdata/master_data_repository.dart';
import '../features/masterdata/master_data_sync.dart';
import '../features/route/printing/printer_service.dart';
import '../features/route/route_service.dart';
import '../features/sync/outbox.dart';
import '../features/sync/outbox_processor.dart';
import 'api_client.dart';
import 'app_config.dart';
import 'app_database.dart';
import 'key_value_store.dart';
import 'token_store.dart';

// Async-initialised singletons, supplied via ProviderScope overrides in main().
final keyValueStoreProvider = Provider<KeyValueStore>((_) => throw UnimplementedError());
final databaseProvider = Provider<AppDatabase>((_) => throw UnimplementedError());
final tokenStoreProvider = Provider<TokenStore>((_) => throw UnimplementedError());
final appConfigProvider = Provider<AppConfig>((_) => throw UnimplementedError());

final apiClientProvider = Provider<ApiClient>(
    (ref) => ApiClient(baseUrl: ref.watch(appConfigProvider).baseUrl, tokens: ref.watch(tokenStoreProvider)));

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(
    api: ref.watch(apiClientProvider), tokens: ref.watch(tokenStoreProvider), kv: ref.watch(keyValueStoreProvider)));

final masterDataRepositoryProvider = Provider<MasterDataRepository>((ref) => MasterDataRepository(ref.watch(databaseProvider)));

final masterDataSyncProvider =
    Provider<MasterDataSync>((ref) => MasterDataSync(ref.watch(apiClientProvider), ref.watch(databaseProvider)));

final outboxRepositoryProvider = Provider<OutboxRepository>((ref) => OutboxRepository(ref.watch(databaseProvider)));

final outboxProcessorProvider =
    Provider<OutboxProcessor>((ref) => OutboxProcessor(ref.watch(apiClientProvider), ref.watch(outboxRepositoryProvider)));

final routeServiceProvider = Provider<RouteService>((ref) =>
    RouteService(ref.watch(databaseProvider), ref.watch(outboxRepositoryProvider), ref.watch(apiClientProvider)));

final printerServiceProvider = Provider<PrinterService>((ref) => PrinterService(ref.watch(keyValueStoreProvider)));

