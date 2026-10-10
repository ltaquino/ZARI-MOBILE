import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

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

    // Route Sales ordering. A truck's invoices must reach ZARI in number order (the server only accepts the
    // terminal's exact next number), and its end-of-trip only after everything else. So once an invoice/void of
    // a trip is stuck, that trip's later invoices/voids wait; once anything of a trip is stuck, its end waits.
    final seriesBlocked = <String>{};
    final endBlocked = <String>{};
    for (final stuck in await _outbox.list(statuses: {OutboxStatus.failed, OutboxStatus.needsReview}, userId: userId)) {
      _blockAfter(stuck, seriesBlocked, endBlocked);
    }

    for (final entry in queue) {
      final tripId = entry.meta['tripId'] as String?;
      if (tripId != null) {
        final isSeries = entry.type == OutboxType.routeSale || entry.type == OutboxType.routeVoid;
        if ((isSeries && seriesBlocked.contains(tripId)) || (entry.type == OutboxType.routeEnd && endBlocked.contains(tripId))) {
          continue; // stays pending until whatever is ahead of it is resolved
        }
        if (entry.type == OutboxType.routePod && !await _dependencySynced(entry)) continue;
      }
      final stop = await _pushOne(entry, report);
      if (stop != PushStop.none) {
        report.stoppedBy = stop;
        break;
      }
      final after = await _outbox.get(entry.id);
      if (after != null && after.status != OutboxStatus.synced) _blockAfter(after, seriesBlocked, endBlocked);
    }
    return report;
  }

  static void _blockAfter(OutboxEntry entry, Set<String> seriesBlocked, Set<String> endBlocked) {
    final tripId = entry.meta['tripId'] as String?;
    if (tripId == null || entry.type == OutboxType.routePod) return;
    endBlocked.add(tripId);
    if (entry.type == OutboxType.routeSale || entry.type == OutboxType.routeVoid) seriesBlocked.add(tripId);
  }

  /// A proof-of-delivery upload goes once the sale it belongs to is in ZARI (its URL needs the sale's id).
  Future<bool> _dependencySynced(OutboxEntry entry) async {
    final dependsOn = entry.meta['dependsOn'] as String?;
    if (dependsOn == null) return true;
    final sale = await _outbox.get(dependsOn);
    return sale != null && sale.status == OutboxStatus.synced && sale.serverId != null;
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
        response = entry.type == OutboxType.routePod ? await _sendPod(entry) : await _send(entry.method, entry.path, entry.body);
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
    // Safe-to-resend endpoints: a lost answer, or the same request still being processed server-side, just means
    // "try again shortly" — stop this run (the connection is evidently unsteady) and leave it pending.
    if (entry.idempotent && (e.kind == ApiFailureKind.ambiguous || e.errorCode == 'RouteSale.InProgress')) {
      await _outbox.markPending(entry.id, error: e.message);
      report.stopMessage = e.message;
      return PushStop.offline;
    }
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
    if (res is Map<String, dynamic>) return res;
    // Route returns/collections/refusals answer with just the new record's id.
    if (res is String && res.isNotEmpty) return {'id': res};
    return <String, dynamic>{};
  }

  /// Signature (and receiver's name) for a route sale — multipart, to the sale's own URL.
  Future<Map<String, dynamic>> _sendPod(OutboxEntry entry) async {
    final sale = await _outbox.get(entry.meta['dependsOn'] as String);
    final path = entry.path.replaceAll('{saleId}', sale!.serverId!);
    final file = entry.body['signatureFile'] as String?;
    final form = FormData.fromMap({
      if (entry.body['receivedByName'] != null) 'receivedByName': entry.body['receivedByName'],
      if (file != null && File(file).existsSync()) 'signature': await MultipartFile.fromFile(file, filename: p.basename(file)),
    });
    await _api.post<dynamic>(path, form);
    return {'id': sale.serverId};
  }

  static String? _extractId(Map<String, dynamic> r) => (r['id'] ?? r['salesInvoiceId']) as String?;

  static String? _extractRef(Map<String, dynamic> r) =>
      (r['invoiceNo'] ?? r['soNo'] ?? r['opnameNo'] ?? r['adjustmentNo'] ?? r['birOrSeriesNumber'] ?? r['tripNo']) as String?;
}
