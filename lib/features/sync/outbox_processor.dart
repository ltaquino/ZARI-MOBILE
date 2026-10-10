import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import 'outbox.dart';

enum PushStop { none, offline, unauthorized }

class PushReport {
  int synced = 0;
  int failed = 0;
  int needsReview = 0;
  PushStop stoppedBy = PushStop.none;
  String? stopMessage;

  bool get didAnything => synced + failed + needsReview > 0;
}

/// Sends pending outbox entries to ZARI, oldest first, one at a time.
///
/// The rule that matters: a create call is only ever re-sent when we *know*
/// it never reached the server. Anything that might have landed goes to
/// `needsReview`, never back to `pending`.
class OutboxProcessor {
  OutboxProcessor(this._api, this._outbox);

  final ApiClient _api;
  final OutboxRepository _outbox;

  Future<PushReport> pushAll({required String userId}) async {
    final report = PushReport();
    final queue = await _outbox.list(statuses: {OutboxStatus.pending}, userId: userId);
    for (final entry in queue) {
      final stop = await _pushOne(entry, report);
      if (stop != PushStop.none) {
        report.stoppedBy = stop;
        break;
      }
    }
    return report;
  }

  /// Retries a single entry on demand (from the Sync screen).
  Future<PushReport> pushEntry(OutboxEntry entry) async {
    final report = PushReport();
    report.stoppedBy = await _pushOne(entry, report);
    return report;
  }

  Future<PushStop> _pushOne(OutboxEntry entry, PushReport report) async {
    await _outbox.markSyncing(entry.id);
    var serverId = entry.serverId;
    var serverRef = entry.serverRef;

    // Step 1 — create, unless a previous attempt already did.
    if (serverId == null) {
      Map<String, dynamic>? response;
      try {
        response = await _send(entry.method, entry.path, entry.body);
      } on ApiException catch (e) {
        return _handleFailure(entry, e, report, createStage: true);
      } catch (e) {
        // Not a transport error (e.g. a malformed response body after a 2xx) —
        // the server may well have saved it.
        await _outbox.markNeedsReview(entry.id, 'Unexpected response from ZARI: $e');
        report.needsReview++;
        return PushStop.none;
      }
      serverId = _extractId(response);
      serverRef = _extractRef(response);
      if (serverId == null) {
        await _outbox.markNeedsReview(entry.id, 'ZARI accepted the request but returned no document id.');
        report.needsReview++;
        return PushStop.none;
      }
      await _outbox.markCreated(entry.id, serverId: serverId, serverRef: serverRef, response: response);
    }

    // Step 2 — optional follow-up (submit for approval). Skipped when the
    // create already moved the document past DRAFT (Company quick-post
    // toggles), and safe to repeat otherwise: ZARI rejects submitting a
    // document that's no longer DRAFT.
    final createdStatus = ((await _outbox.get(entry.id))?.serverResponse?['status'] as String?)?.toUpperCase();
    if (entry.followUpPath != null && (createdStatus == null || createdStatus == 'DRAFT')) {
      try {
        await _send('POST', entry.followUpPath!.replaceAll('{id}', serverId), entry.followUpBody ?? const {});
      } on ApiException catch (e) {
        if (e.kind == ApiFailureKind.offline || e.kind == ApiFailureKind.unauthorized) {
          return _handleFailure(entry, e, report, createStage: false);
        }
        await _outbox.markFailed(entry.id,
            'Saved in ZARI as ${serverRef ?? serverId}, but the follow-up step failed: ${e.message} Retry only repeats that step.');
        report.failed++;
        return PushStop.none;
      }
    }

    await _outbox.markSynced(entry.id);
    report.synced++;
    return PushStop.none;
  }

  Future<PushStop> _handleFailure(OutboxEntry entry, ApiException e, PushReport report, {required bool createStage}) async {
    switch (e.kind) {
      case ApiFailureKind.offline:
        await _outbox.markPending(entry.id, error: e.message);
        report.stopMessage = e.message;
        return PushStop.offline;
      case ApiFailureKind.unauthorized:
        await _outbox.markPending(entry.id, error: e.message);
        report.stopMessage = e.message;
        return PushStop.unauthorized;
      case ApiFailureKind.ambiguous:
        if (createStage) {
          await _outbox.markNeedsReview(entry.id, e.message);
          report.needsReview++;
        } else {
          await _outbox.markFailed(entry.id, e.message);
          report.failed++;
        }
        return PushStop.none;
      default:
        await _outbox.markFailed(entry.id, e.message);
        report.failed++;
        return PushStop.none;
    }
  }

  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic> body) async {
    final dynamic res = method == 'PUT' ? await _api.put<dynamic>(path, body) : await _api.post<dynamic>(path, body);
    return res is Map<String, dynamic> ? res : <String, dynamic>{};
  }

  static String? _extractId(Map<String, dynamic> r) => (r['id'] ?? r['salesInvoiceId']) as String?;

  static String? _extractRef(Map<String, dynamic> r) =>
      (r['invoiceNo'] ?? r['soNo'] ?? r['opnameNo'] ?? r['adjustmentNo']) as String?;
}
