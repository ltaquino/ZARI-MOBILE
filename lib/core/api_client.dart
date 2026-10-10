import 'dart:async';

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'token_store.dart';

/// Thin wrapper over Dio that speaks ZARI's conventions: bearer JWT, one
/// silent refresh on 401 via POST /api/identity/refresh (de-duplicated across
/// concurrent calls, same as ZARI-FE's apiClient.ts), and RFC 7807
/// ProblemDetails error bodies flattened into a readable message.
class ApiClient {
  ApiClient({required String baseUrl, required TokenStore tokens, Dio? dio})
      : _tokens = tokens,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
              contentType: Headers.jsonContentType,
              responseType: ResponseType.json,
            )) {
    this.baseUrl = baseUrl;
  }

  final Dio _dio;
  final TokenStore _tokens;
  Future<bool>? _refreshInFlight;

  /// Called after the refresh token itself is rejected — the user has to sign
  /// in online again before anything else can sync.
  void Function()? onSessionExpired;

  String get baseUrl => _dio.options.baseUrl;
  set baseUrl(String value) => _dio.options.baseUrl = value.replaceAll(RegExp(r'/+$'), '');

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _send<T>(() => _dio.get<dynamic>(path, queryParameters: query, options: _authOptions()), path);

  Future<T> post<T>(String path, Object? body) =>
      _send<T>(() => _dio.post<dynamic>(path, data: body, options: _authOptions()), path);

  Future<T> put<T>(String path, Object? body) =>
      _send<T>(() => _dio.put<dynamic>(path, data: body, options: _authOptions()), path);

  Future<void> delete(String path) => _send<dynamic>(() => _dio.delete<dynamic>(path, options: _authOptions()), path);

  /// Cheap reachability probe — any HTTP response at all (even 404/401) means
  /// the server is up; only a transport failure means it isn't.
  Future<bool> ping() async {
    try {
      await _dio.get<dynamic>('/health',
          options: Options(
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            validateStatus: (_) => true,
          ));
      return true;
    } on DioException {
      return false;
    }
  }

  Options _authOptions() {
    final token = _tokens.current?.accessToken;
    return Options(headers: token == null ? null : {'Authorization': 'Bearer $token'});
  }

  Future<T> _send<T>(Future<Response<dynamic>> Function() call, String path, {bool isRetry = false}) async {
    try {
      final res = await call();
      return res.data as T;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 && !isRetry && !path.startsWith('/api/identity/')) {
        _refreshInFlight ??= _refresh().whenComplete(() => _refreshInFlight = null);
        if (await _refreshInFlight!) return _send<T>(call, path, isRetry: true);
        throw ApiException(ApiFailureKind.unauthorized, 'Your session has expired. Sign in again to continue syncing.',
            statusCode: 401);
      }
      throw mapDioException(e);
    }
  }

  Future<bool> _refresh() async {
    final current = _tokens.current;
    if (current == null) return false;
    try {
      final res = await _dio.post<dynamic>('/api/identity/refresh',
          data: {'accessToken': current.accessToken, 'refreshToken': current.refreshToken});
      // The user may have logged out while this was in flight — don't resurrect the session.
      if (_tokens.current?.refreshToken != current.refreshToken) return false;
      final data = res.data as Map<String, dynamic>;
      final jwt = data['jwToken'] as String?;
      final refresh = data['refreshToken'] as String?;
      if (jwt == null || jwt.isEmpty || refresh == null || refresh.isEmpty) return false;
      await _tokens.save(AuthTokens(accessToken: jwt, refreshToken: refresh, userId: current.userId));
      return true;
    } on DioException catch (e) {
      final mapped = mapDioException(e);
      if (mapped.kind == ApiFailureKind.offline || mapped.kind == ApiFailureKind.ambiguous) {
        // Can't tell yet whether the refresh token is still good — keep it for next time.
        throw mapped;
      }
      onSessionExpired?.call();
      return false;
    }
  }
}

ApiException mapDioException(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.badCertificate:
      return ApiException(ApiFailureKind.offline, 'Cannot reach the ZARI server.');
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
    case DioExceptionType.cancel:
    case DioExceptionType.unknown:
      return ApiException(ApiFailureKind.ambiguous,
          'The connection dropped before the server answered (${e.type.name}). The server may or may not have saved it.');
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode ?? 0;
      final parsed = _parseProblem(e.response?.data, e.response?.statusMessage, status);
      final kind = switch (status) {
        401 => ApiFailureKind.unauthorized,
        403 => ApiFailureKind.forbidden,
        404 => ApiFailureKind.notFound,
        409 => ApiFailureKind.conflict,
        >= 500 => ApiFailureKind.server,
        _ => ApiFailureKind.validation,
      };
      return ApiException(kind, parsed.$1, statusCode: status, errors: parsed.$2);
  }
}

(String, Map<String, List<String>>?) _parseProblem(dynamic body, String? statusText, int status) {
  if (body is Map) {
    final errors = body['errors'];
    if (errors is Map && errors.isNotEmpty) {
      final map = <String, List<String>>{
        for (final entry in errors.entries)
          entry.key.toString(): (entry.value is List ? entry.value as List : [entry.value]).map((v) => '$v').toList(),
      };
      return (map.values.expand((v) => v).join(' '), map);
    }
    final detail = body['detail'] ?? body['title'];
    if (detail is String && detail.isNotEmpty) return (detail, null);
  }
  return (statusText?.isNotEmpty == true ? statusText! : 'Request failed with status $status', null);
}
