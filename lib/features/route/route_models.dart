/// Shapes of GET /api/trips/mine (the truck handheld's download) — ZARI's DeviceTripBundle — plus the
/// invoice-number arithmetic for the handheld's own BIR series.
library;

double _d(Object? v) => v == null ? 0 : (v as num).toDouble();
double? _dn(Object? v) => v == null ? null : (v as num).toDouble();

abstract final class TripStatus {
  static const loaded = 'LOADED';
  static const inTransit = 'IN_TRANSIT';
  static const pendingClose = 'PENDING_CLOSE_APPROVAL';
}

class TripLineInfo {
  const TripLineInfo({
    required this.itemId,
    required this.itemCode,
    required this.itemName,
    required this.uomId,
    required this.qtyLoaded,
    required this.qtyDelivered,
    required this.qtyVanSold,
    required this.qtyRefused,
    required this.qtyReturnedGood,
    required this.qtyReturnedDamaged,
    required this.qtyExpectedOnTruck,
    this.qtyLoadCheck,
  });

  final String itemId;
  final String itemCode;
  final String itemName;
  final String uomId;
  final double qtyLoaded;
  final double? qtyLoadCheck;
  final double qtyDelivered;
  final double qtyVanSold;
  final double qtyRefused;
  final double qtyReturnedGood;
  final double qtyReturnedDamaged;
  final double qtyExpectedOnTruck;

  factory TripLineInfo.fromJson(Map<String, dynamic> j) => TripLineInfo(
        itemId: j['itemId'] as String,
        itemCode: j['itemCode'] as String,
        itemName: j['itemName'] as String,
        uomId: j['uomId'] as String,
        qtyLoaded: _d(j['qtyLoaded']),
        qtyLoadCheck: _dn(j['qtyLoadCheck']),
        qtyDelivered: _d(j['qtyDelivered']),
        qtyVanSold: _d(j['qtyVanSold']),
        qtyRefused: _d(j['qtyRefused']),
        qtyReturnedGood: _d(j['qtyReturnedGood']),
        qtyReturnedDamaged: _d(j['qtyReturnedDamaged']),
        qtyExpectedOnTruck: _d(j['qtyExpectedOnTruck']),
      );
}

class TripInfo {
  const TripInfo({
    required this.id,
    required this.tripNo,
    required this.branchId,
    required this.vehicleCode,
    required this.plateNo,
    required this.posTerminalId,
    required this.tripDate,
    required this.status,
    required this.cashExpected,
    required this.lines,
    this.helperNames,
  });

  final String id;
  final String tripNo;
  final String branchId;
  final String vehicleCode;
  final String plateNo;
  final String posTerminalId;
  final DateTime tripDate;
  final String status;
  final double cashExpected;
  final String? helperNames;
  final List<TripLineInfo> lines;

  factory TripInfo.fromJson(Map<String, dynamic> j) => TripInfo(
        id: j['id'] as String,
        tripNo: j['tripNo'] as String,
        branchId: j['branchId'] as String,
        vehicleCode: j['vehicleCode'] as String,
        plateNo: j['plateNo'] as String,
        posTerminalId: j['posTerminalId'] as String,
        tripDate: DateTime.parse(j['tripDate'] as String),
        status: j['status'] as String,
        cashExpected: _d(j['cashExpected']),
        helperNames: j['helperNames'] as String?,
        lines: [for (final l in (j['lines'] as List? ?? const [])) TripLineInfo.fromJson(l as Map<String, dynamic>)],
      );
}

class OrderLineInfo {
  const OrderLineInfo({
    required this.salesOrderLineId,
    required this.itemId,
    required this.uomId,
    required this.qty,
    required this.qtyRemaining,
    required this.unitPrice,
    required this.discountPct,
  });

  final String salesOrderLineId;
  final String itemId;
  final String uomId;
  final double qty;

  /// Still to deliver on this trip, as of the download.
  final double qtyRemaining;
  final double unitPrice;
  final double discountPct;

  factory OrderLineInfo.fromJson(Map<String, dynamic> j) => OrderLineInfo(
        salesOrderLineId: j['salesOrderLineId'] as String,
        itemId: j['itemId'] as String,
        uomId: j['uomId'] as String,
        qty: _d(j['qty']),
        qtyRemaining: _d(j['qtyRemaining']),
        unitPrice: _d(j['unitPrice']),
        discountPct: _d(j['discountPct']),
      );
}

class OrderInfo {
  const OrderInfo({
    required this.id,
    required this.soNo,
    required this.customerId,
    required this.customerName,
    required this.lines,
    this.discountPct,
  });

  final String id;
  final String soNo;
  final String customerId;
  final String customerName;
  final double? discountPct;
  final List<OrderLineInfo> lines;

  factory OrderInfo.fromJson(Map<String, dynamic> j) => OrderInfo(
        id: j['id'] as String,
        soNo: j['soNo'] as String,
        customerId: j['customerId'] as String,
        customerName: j['customerName'] as String,
        discountPct: _dn(j['discountPct']),
        lines: [for (final l in (j['lines'] as List? ?? const [])) OrderLineInfo.fromJson(l as Map<String, dynamic>)],
      );
}

class OpenInvoiceInfo {
  const OpenInvoiceInfo({
    required this.salesInvoiceId,
    required this.invoiceNo,
    required this.invoiceDate,
    required this.balance,
    this.birOrSeriesNumber,
  });

  final String salesInvoiceId;
  final String invoiceNo;
  final String? birOrSeriesNumber;
  final DateTime invoiceDate;
  final double balance;

  String get label => birOrSeriesNumber ?? invoiceNo;

  factory OpenInvoiceInfo.fromJson(Map<String, dynamic> j) => OpenInvoiceInfo(
        salesInvoiceId: j['salesInvoiceId'] as String,
        invoiceNo: j['invoiceNo'] as String,
        birOrSeriesNumber: j['birOrSeriesNumber'] as String?,
        invoiceDate: DateTime.parse(j['invoiceDate'] as String),
        balance: _d(j['balance']),
      );
}

class StopInfo {
  const StopInfo({
    required this.customerId,
    required this.customerName,
    required this.sequence,
    required this.openBalance,
    required this.openInvoices,
    this.notes,
    this.creditLimit,
    this.address,
    this.tin,
  });

  final String customerId;
  final String customerName;
  final int sequence;
  final String? notes;

  /// What the customer owed on posted invoices at download time.
  final double openBalance;
  final double? creditLimit;
  final String? address;
  final String? tin;
  final List<OpenInvoiceInfo> openInvoices;

  factory StopInfo.fromJson(Map<String, dynamic> j) => StopInfo(
        customerId: j['customerId'] as String,
        customerName: j['customerName'] as String,
        sequence: (j['sequence'] as num).toInt(),
        notes: j['notes'] as String?,
        openBalance: _d(j['openBalance']),
        creditLimit: _dn(j['creditLimit']),
        address: j['address'] as String?,
        tin: j['tin'] as String?,
        openInvoices: [
          for (final i in (j['openInvoices'] as List? ?? const [])) OpenInvoiceInfo.fromJson(i as Map<String, dynamic>)
        ],
      );
}

class RefusalReason {
  const RefusalReason(this.code, this.label);
  final String code;
  final String label;

  static const other = 'OTHER';

  factory RefusalReason.fromJson(Map<String, dynamic> j) => RefusalReason(j['code'] as String, j['label'] as String);
}

/// The seller details a BIR invoice must show — sent with the trip because the driver can't read Company Settings.
class InvoiceHeader {
  const InvoiceHeader({
    required this.registeredName,
    required this.branchName,
    this.tradeName,
    this.tin,
    this.registeredAddress,
    this.vatRegistrationType,
    this.branchAddress,
    this.birBranchCode,
  });

  final String registeredName;
  final String? tradeName;
  final String? tin;
  final String? registeredAddress;
  final String? vatRegistrationType;
  final String branchName;
  final String? branchAddress;
  final String? birBranchCode;

  bool get isVatRegistered => vatRegistrationType != 'NON_VAT';

  factory InvoiceHeader.fromJson(Map<String, dynamic>? j) => j == null
      ? const InvoiceHeader(registeredName: '', branchName: '')
      : InvoiceHeader(
          registeredName: j['registeredName'] as String? ?? '',
          tradeName: j['tradeName'] as String?,
          tin: j['tin'] as String?,
          registeredAddress: j['registeredAddress'] as String?,
          vatRegistrationType: j['vatRegistrationType'] as String?,
          branchName: j['branchName'] as String? ?? '',
          branchAddress: j['branchAddress'] as String?,
          birBranchCode: j['birBranchCode'] as String?,
        );
}

class TripBundle {
  const TripBundle({
    required this.trip,
    required this.nextInvoiceNumber,
    required this.salesOrders,
    required this.stops,
    required this.recordedInvoiceNumbers,
    required this.refusalReasons,
    required this.header,
    this.machineIdentificationNumber,
    this.machineSerialNumber,
    this.posPermitNumber,
    this.posPermitDateIssued,
  });

  final TripInfo trip;
  final String nextInvoiceNumber;
  final String? machineIdentificationNumber;
  final String? machineSerialNumber;
  final String? posPermitNumber;
  final DateTime? posPermitDateIssued;
  final List<OrderInfo> salesOrders;
  final List<StopInfo> stops;
  final List<String> recordedInvoiceNumbers;
  final List<RefusalReason> refusalReasons;
  final InvoiceHeader header;

  factory TripBundle.fromJson(Map<String, dynamic> j) => TripBundle(
        trip: TripInfo.fromJson(j['trip'] as Map<String, dynamic>),
        nextInvoiceNumber: j['nextInvoiceNumber'] as String,
        machineIdentificationNumber: j['machineIdentificationNumber'] as String?,
        machineSerialNumber: j['machineSerialNumber'] as String?,
        posPermitNumber: j['posPermitNumber'] as String?,
        posPermitDateIssued: j['posPermitDateIssued'] == null ? null : DateTime.parse(j['posPermitDateIssued'] as String),
        salesOrders: [for (final o in (j['salesOrders'] as List? ?? const [])) OrderInfo.fromJson(o as Map<String, dynamic>)],
        stops: [for (final s in (j['stops'] as List? ?? const [])) StopInfo.fromJson(s as Map<String, dynamic>)],
        recordedInvoiceNumbers: [for (final n in (j['recordedInvoiceNumbers'] as List? ?? const [])) n as String],
        refusalReasons: [
          for (final r in (j['refusalReasons'] as List? ?? const [])) RefusalReason.fromJson(r as Map<String, dynamic>)
        ],
        header: InvoiceHeader.fromJson(j['invoiceHeader'] as Map<String, dynamic>?),
      );

  StopInfo? stopFor(String customerId) => stops.where((s) => s.customerId == customerId).firstOrNull;
  List<OrderInfo> ordersFor(String customerId) => salesOrders.where((o) => o.customerId == customerId).toList();
}

/// A handheld invoice number: prefix + zero-padded counter, e.g. `T1-000501`.
class InvoiceSeries {
  const InvoiceSeries({required this.prefix, required this.padding, required this.next});

  final String prefix;
  final int padding;
  final int next;

  /// Splits ZARI's formatted next number into its parts (the counter is the trailing digits).
  static InvoiceSeries parse(String formatted) {
    final m = RegExp(r'^(.*?)(\d+)$').firstMatch(formatted);
    if (m == null) throw FormatException('Not an invoice number: $formatted');
    return InvoiceSeries(prefix: m.group(1)!, padding: m.group(2)!.length, next: int.parse(m.group(2)!));
  }

  String format(int n) => '$prefix${n.toString().padLeft(padding, '0')}';
  String get nextFormatted => format(next);
}
