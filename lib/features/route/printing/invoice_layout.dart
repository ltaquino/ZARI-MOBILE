import 'package:intl/intl.dart';

import '../route_ledger.dart';
import '../route_models.dart';
import 'escpos.dart';

final _amount = NumberFormat('#,##0.00');
final _qty = NumberFormat('#,##0.##');
final _when = DateFormat('yyyy-MM-dd HH:mm');
final _day = DateFormat('yyyy-MM-dd');

String _m(num v) => _amount.format(v);

/// The printed Sales Invoice for a route sale — what BIR requires on a machine-issued invoice: the seller's
/// registered name, TIN and address, the invoice's serial number and date, the buyer, the items, the VAT breakdown,
/// and the machine's MIN/serial and permit-to-use. The same lines drive the on-screen preview and the printer.
List<PrintLine> invoiceLines(TripBundle bundle, RouteEvent sale, {required int width, bool reprint = false}) {
  final h = bundle.header;
  final d = sale.data;
  final stop = bundle.stopFor(sale.customerId ?? '');
  final out = <PrintLine>[];
  void center(String s, {bool bold = false, bool big = false}) {
    for (final l in Cols.wrap(s, big ? width ~/ 2 : width)) {
      out.add(PrintLine(l, align: PrintAlign.center, bold: bold, big: big));
    }
  }

  void left(String s, {bool bold = false}) {
    for (final l in Cols.wrap(s, width)) {
      out.add(PrintLine(l, bold: bold));
    }
  }

  void row(String l, String r, {bool bold = false}) => out.add(PrintLine(Cols.row(l, r, width), bold: bold));
  void rule() => out.add(PrintLine(Cols.rule(width)));

  if (reprint) center('*** REPRINT ***', bold: true);
  center(h.registeredName.isEmpty ? 'SELLER NAME NOT SET' : h.registeredName, bold: true);
  if ((h.tradeName ?? '').isNotEmpty) center(h.tradeName!);
  center('${h.isVatRegistered ? 'VAT REG TIN' : 'NON-VAT REG TIN'}: ${h.tin ?? '-'}${(h.birBranchCode ?? '').isEmpty ? '' : '-${h.birBranchCode}'}');
  if ((h.registeredAddress ?? '').isNotEmpty) center(h.registeredAddress!);
  if (h.branchName.isNotEmpty) center(h.branchName);
  if ((h.branchAddress ?? '').isNotEmpty && h.branchAddress != h.registeredAddress) center(h.branchAddress!);
  if ((bundle.machineIdentificationNumber ?? '').isNotEmpty) center('MIN: ${bundle.machineIdentificationNumber}');
  if ((bundle.machineSerialNumber ?? '').isNotEmpty) center('SN: ${bundle.machineSerialNumber}');
  out.add(const PrintLine(''));
  center('SALES INVOICE', bold: true, big: true);
  row('No.', sale.invoiceNumber ?? '-', bold: true);
  row('Date', _when.format(DateTime.parse(d['soldAt'] as String).toLocal()));
  row('Truck', bundle.trip.vehicleCode);
  row('Trip', bundle.trip.tripNo);
  rule();
  left('Sold to: ${d['customerName'] ?? stop?.customerName ?? ''}', bold: true);
  left('TIN: ${(stop?.tin ?? '').isEmpty ? '____________________' : stop!.tin}');
  left('Address: ${(stop?.address ?? '').isEmpty ? '____________________' : stop!.address}');
  if (d['soNo'] != null) left('Ref. SO: ${d['soNo']}');
  rule();

  for (final l in sale.lines) {
    final q = (l['qty'] as num).toDouble();
    final price = (l['unitPrice'] as num).toDouble();
    final disc = (l['discountPct'] as num? ?? 0).toDouble();
    final gross = q * price;
    left('${l['itemName']}');
    row('  ${_qty.format(q)} x ${_m(price)}${disc > 0 ? ' less ${_qty.format(disc)}%' : ''}${l['vatType'] == 'VAT_EXEMPT' ? ' E' : l['vatType'] == 'ZERO_RATED' ? ' Z' : ''}',
        _m(gross * (1 - disc / 100)));
  }
  rule();
  final discount = (d['discount'] as num? ?? 0).toDouble();
  if (discount > 0.004) row('Less discount', '-${_m(discount)}');
  row('TOTAL AMOUNT DUE', _m(d['total'] as num), bold: true);
  if (h.isVatRegistered) {
    row('VATable sales', _m(d['vatableSales'] as num? ?? 0));
    row('VAT (12%)', _m(d['vat'] as num? ?? 0));
  }
  row('VAT-exempt sales', _m(d['vatExemptSales'] as num? ?? 0));
  row('Zero-rated sales', _m(d['zeroRatedSales'] as num? ?? 0));
  rule();
  for (final t in (d['tenders'] as List? ?? const [])) {
    final m = t as Map<String, dynamic>;
    row('${m['name']}${(m['referenceNo'] ?? '').toString().isEmpty ? '' : ' #${m['referenceNo']}'}', _m(m['amount'] as num));
  }
  if ((d['change'] as num? ?? 0) > 0) row('Change', _m(d['change'] as num));
  if ((d['charged'] as num? ?? 0) > 0.004) row('Charged to account', _m(d['charged'] as num), bold: true);

  final refusals = sale.refusals;
  if (refusals.isNotEmpty) {
    rule();
    left('Not delivered:');
    for (final r in refusals) {
      final reason = bundle.refusalReasons.where((x) => x.code == r['reasonCode']).firstOrNull?.label ?? '${r['reasonCode']}';
      final code = sale.lines.where((l) => l['itemId'] == r['itemId']).firstOrNull?['itemName'] ?? r['itemId'];
      left('  $code x${_qty.format(r['qty'] as num)} - $reason${(r['notes'] ?? '').toString().isEmpty ? '' : ' (${r['notes']})'}');
    }
  }
  rule();
  out.add(const PrintLine(''));
  left('Received by: ${d['receivedByName'] ?? ''}');
  out.add(PrintLine('_' * (width * 2 ~/ 3), align: PrintAlign.center));
  center('Signature over printed name');
  out.add(const PrintLine(''));
  if ((bundle.posPermitNumber ?? '').isNotEmpty) {
    center('PTU No.: ${bundle.posPermitNumber}');
    if (bundle.posPermitDateIssued != null) center('Date issued: ${_day.format(bundle.posPermitDateIssued!)}');
  }
  if (!h.isVatRegistered) center('THIS DOCUMENT IS NOT VALID FOR CLAIM OF INPUT TAX.', bold: true);
  center('Thank you!');
  if (reprint) center('*** REPRINT ***', bold: true);
  return out;
}

/// End-of-trip slip for the driver to hand in with the cash: what was sold, collected and counted.
List<PrintLine> tripSummaryLines(TripBundle bundle, TripLedger ledger, {required int width, Map<String, double>? counts, double? cashRemitted}) {
  final out = <PrintLine>[];
  void row(String l, String r, {bool bold = false}) => out.add(PrintLine(Cols.row(l, r, width), bold: bold));
  out
    ..add(const PrintLine('TRIP SUMMARY', align: PrintAlign.center, bold: true, big: true))
    ..add(PrintLine(bundle.trip.tripNo, align: PrintAlign.center))
    ..add(PrintLine('${bundle.trip.vehicleCode} · ${_day.format(bundle.trip.tripDate.toLocal())}', align: PrintAlign.center))
    ..add(PrintLine(Cols.rule(width)));
  row('Invoices issued', '${ledger.invoiceCount}');
  row('Voided numbers', '${ledger.voidCount}');
  row('Sales total', _m(ledger.salesTotal));
  row('Cash expected', _m(ledger.cashExpected), bold: true);
  if (cashRemitted != null) row('Cash handed in', _m(cashRemitted), bold: true);
  out.add(PrintLine(Cols.rule(width)));
  out.add(PrintLine(Cols.row('Item', 'Expected / Counted', width), bold: true));
  for (final i in ledger.countSheet) {
    final counted = counts?[i.itemId];
    row(i.code, '${_qty.format(i.onTruck)} / ${counted == null ? '-' : _qty.format(counted)}');
  }
  out
    ..add(PrintLine(Cols.rule(width)))
    ..add(const PrintLine(''))
    ..add(PrintLine('Driver: ${'_' * (width - 8)}'))
    ..add(const PrintLine(''))
    ..add(PrintLine('Received: ${'_' * (width - 10)}'));
  return out;
}
