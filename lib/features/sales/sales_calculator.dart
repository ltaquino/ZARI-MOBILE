import '../masterdata/models.dart';

/// Dart mirror of ZARI's SalesInvoiceLineCalculator (backend) and
/// ZARI-FE's features/sales/salesInvoices/calculator.ts — same order of
/// operations, so totals shown offline match what ZARI posts on sync.
const vatRate = 0.12;

double round4(double v) => (v * 10000).roundToDouble() / 10000;
double round2(double v) => (v * 100).roundToDouble() / 100;

class LineCalc {
  const LineCalc({required this.gross, required this.discount, required this.net, required this.effectiveVatType});

  final double gross;
  final double discount;

  /// Before the document's header discount.
  final double net;
  final VatType effectiveVatType;
}

LineCalc calculateLine({
  required double qty,
  required double unitPrice,
  required double discountPct,
  required VatType vatType,
  double? statutoryDiscountPct,
}) {
  final gross = round4(qty * unitPrice);
  if (statutoryDiscountPct != null) {
    // Senior/PWD/etc.: strip VAT first to get the VAT-exempt base, then apply the fixed %.
    final base = round4(gross / (1 + vatRate));
    final discount = round4(base * (statutoryDiscountPct / 100));
    return LineCalc(gross: gross, discount: discount, net: base - discount, effectiveVatType: VatType.vatExempt);
  }
  final discount = round4(gross * (discountPct / 100));
  return LineCalc(gross: gross, discount: discount, net: gross - discount, effectiveVatType: vatType);
}

({double netOfVat, double vat}) splitVat(double net, VatType type) {
  if (type != VatType.vatable) return (netOfVat: net, vat: 0);
  final vat = round4((net * vatRate) / (1 + vatRate));
  return (netOfVat: net - vat, vat: vat);
}

class CartLine {
  CartLine({
    required this.key,
    required this.item,
    required this.qty,
    required this.unitPrice,
    this.discountPct = 0,
    this.statutoryDiscountTypeId,
    this.statutoryDiscountPct,
    this.statutoryIdNumber,
    this.serialNo,
    this.defaultWarehouseId,
  });

  final String key;
  final Item item;
  double qty;
  double unitPrice;
  double discountPct;
  String? statutoryDiscountTypeId;
  double? statutoryDiscountPct;
  String? statutoryIdNumber;
  String? serialNo;
  final String? defaultWarehouseId;

  LineCalc get calc => calculateLine(
        qty: qty,
        unitPrice: unitPrice,
        discountPct: discountPct,
        vatType: item.vatType,
        statutoryDiscountPct: statutoryDiscountTypeId == null ? null : statutoryDiscountPct,
      );
}

class CartTotals {
  const CartTotals({
    required this.gross,
    required this.discount,
    required this.vatableSales,
    required this.vatExemptSales,
    required this.zeroRatedSales,
    required this.vat,
    required this.total,
  });

  final double gross;
  final double discount;
  final double vatableSales;
  final double vatExemptSales;
  final double zeroRatedSales;
  final double vat;
  final double total;

  static CartTotals of(List<CartLine> lines, {double headerDiscountPct = 0}) {
    var gross = 0.0, discount = 0.0, vatable = 0.0, exempt = 0.0, zero = 0.0, vat = 0.0, total = 0.0;
    for (final line in lines) {
      final c = line.calc;
      // Same 4-dp rounding as SalesInvoicePaymentBalance.GetInvoiceTotal — a
      // non-cash tender must equal the server's total exactly.
      final netAfterHeader = round4(c.net * (1 - headerDiscountPct / 100));
      final split = splitVat(netAfterHeader, c.effectiveVatType);
      gross += c.gross;
      discount += c.gross - netAfterHeader;
      switch (c.effectiveVatType) {
        case VatType.vatable:
          vatable += split.netOfVat;
        case VatType.vatExempt:
          exempt += netAfterHeader;
        case VatType.zeroRated:
          zero += netAfterHeader;
      }
      vat += split.vat;
      total += netAfterHeader;
    }
    return CartTotals(
        gross: gross,
        discount: discount,
        vatableSales: vatable,
        vatExemptSales: exempt,
        zeroRatedSales: zero,
        vat: vat,
        total: round4(total));
  }
}
