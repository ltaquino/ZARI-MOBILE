import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zari_mobile/core/api_client.dart';
import 'package:zari_mobile/core/app_database.dart';
import 'package:zari_mobile/core/key_value_store.dart';
import 'package:zari_mobile/core/token_store.dart';

/// What the fake server does with one request.
sealed class FakeReply {}

class Json extends FakeReply {
  Json(this.body, {this.status = 200});
  final Object? body;
  final int status;
}

/// Transport-level failure (DioExceptionType.*).
class Fail extends FakeReply {
  Fail(this.type);
  final DioExceptionType type;
}

typedef FakeHandler = FakeReply Function(RequestOptions req, Map<String, dynamic>? body);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  FakeHandler handler;
  final List<String> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Map<String, dynamic>? body;
    if (options.data is Map) body = (options.data as Map).cast<String, dynamic>();
    calls.add('${options.method} ${options.uri.path}');
    final reply = handler(options, body);
    switch (reply) {
      case Fail(:final type):
        throw DioException(requestOptions: options, type: type);
      case Json(:final body, :final status):
        return ResponseBody.fromString(jsonEncode(body), status, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
    }
  }

  @override
  void close({bool force = false}) {}
}

class TestEnv {
  TestEnv._(this.db, this.kv, this.tokens, this.adapter, this.api);

  final AppDatabase db;
  final MemoryKeyValueStore kv;
  final TokenStore tokens;
  final FakeAdapter adapter;
  final ApiClient api;

  static Future<TestEnv> create([FakeHandler? handler]) async {
    sqfliteFfiInit();
    final db = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final kv = MemoryKeyValueStore();
    final tokens = TokenStore(kv);
    final adapter = FakeAdapter(handler ?? (_, __) => Json({}, status: 404));
    final dio = Dio(BaseOptions(contentType: Headers.jsonContentType))..httpClientAdapter = adapter;
    final api = ApiClient(baseUrl: 'http://zari.test', tokens: tokens, dio: dio);
    return TestEnv._(db, kv, tokens, adapter, api);
  }

  Future<void> close() => db.db.close();
}

Map<String, dynamic> problem(String detail, {int status = 400}) =>
    {'type': 'https://tools.ietf.org/html/rfc9110#section-15.5.1', 'title': 'Bad Request', 'status': status, 'detail': detail};
