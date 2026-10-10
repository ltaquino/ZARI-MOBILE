/// How a failed API call should be treated by callers — above all by the sync
/// engine, which must never blindly re-send a document the server may already
/// have committed (ZARI's create endpoints have no idempotency key).
enum ApiFailureKind {
  /// The request never reached the server (no route, DNS, refused, connect
  /// timeout, TLS handshake). Always safe to retry later.
  offline,

  /// The request may have reached the server but no response came back
  /// (send/receive timeout, connection dropped mid-flight). The document may
  /// or may not exist server-side — needs human review before re-sending.
  ambiguous,

  /// Access token rejected and the refresh token could not renew it.
  unauthorized,

  forbidden,
  notFound,
  validation,
  conflict,
  server,
}

class ApiException implements Exception {
  ApiException(this.kind, this.message, {this.statusCode, this.errors});

  final ApiFailureKind kind;
  final String message;
  final int? statusCode;
  final Map<String, List<String>>? errors;

  /// True when the request provably never reached the server.
  bool get isRetrySafe => kind == ApiFailureKind.offline;

  /// True when the server received and explicitly rejected the request.
  bool get isRejection => switch (kind) {
        ApiFailureKind.forbidden ||
        ApiFailureKind.notFound ||
        ApiFailureKind.validation ||
        ApiFailureKind.conflict ||
        ApiFailureKind.server =>
          true,
        _ => false,
      };

  @override
  String toString() => 'ApiException($kind, $statusCode): $message';
}
