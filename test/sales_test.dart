import 'package:flutter_test/flutter_test.dart';
import 'package:zari_mobile/features/masterdata/models.dart';
import 'package:zari_mobile/features/sales/pos_service.dart';
import 'package:zari_mobile/features/sales/sales_calculator.dart';

Item _item({
  String id = 'i1',
  String code = 'RICE-25',
  VatType vat = VatType.vatable,
  bool serialized = false,
  bool stocked = true,
  bool allowNegative = false,
}) =>
    Item(
      id: id,
      code: code,
      name: code,
      baseUomId: 'uom-1',
      vatType: vat,
      status: 'active',
      isSold: true,
      isStocked: stocked,
      isSerialized: serialized,
      isBatchTracked: false,
      allowNegativeStock: allowNegative,
    );

CartLine _line(Item item, {double qty = 1, double price = 100, double disc = 0, String? wh = 'wh-1'}) =>
    CartLine(key: item.id, item: item, qty: qty, unitPrice: price, discountPct: disc, defaultWarehouseId: wh);

RefRecord _method(String code, {bool needsRef = false}) =>
    RefRecord(RefEntity.paymentMethod, {'id': 'pm-$code', 'code': code, 'name': code, 'requiresReferenceNo': needsRef});

void main() {
  group('calculator (mirror of SalesInvoiceLineCalculator)', () {
    test('VATable line splits 12% VAT out of the VAT-inclusive price', () {
      final t = CartTotals.of([_line(_item(), qty: 2, price: 112)]);
      expect(t.total, 224);
      expect(t.vat, closeTo(24, 1e-9));
      expect(t.vatableSales, closeTo(200, 1e-9));
    });

    test('statutory discount strips VAT first, then applies the fixed %', () {
      final l = _line(_item(), price: 112)
        ..statutoryDiscountTypeId = 'sc'
        ..statutoryDiscountPct = 20;
      final c = l.calc;
      expect(c.effectiveVatType, VatType.vatExempt);
      expect(c.net, closeTo(80, 1e-9)); // 112/1.12 = 100, less 20%
      expect(CartTotals.of([l]).vat, 0);
    });

    test('header discount applies after line discounts, rounded to 4 dp per line', () {
      final t = CartTotals.of([_line(_item(), price: 99.99, disc: 10)], headerDiscountPct: 3.5);
      // 99.99 * 0.9 = 89.991 → * 0.965 = 86.841315 → 86.8413
      expect(t.total, 86.8413);
    });
  });

  group('POS cart validation (mirror of CreatePosSaleCommandHandler)', () {
    List<String> validate(List<CartLine> lines, {double header = 0, double? cap, Map<String, double>? avail}) =>
        validatePosCart(
          lines: lines,
          headerDiscountPct: header,
          maxUnapprovedDiscountPct: cap,
          availableQty: avail ?? {for (final l in lines) l.item.id: 1000},
        );

    test('discount over the company cap is refused offline', () {
      expect(validate([_line(_item(), disc: 15)], cap: 10), isNotEmpty);
      expect(validate([_line(_item())], header: 12, cap: 10), isNotEmpty);
      expect(validate([_line(_item(), disc: 10)], cap: 10), isEmpty);
    });

    test('statutory discounts do not count toward the cap', () {
      final l = _line(_item(), disc: 0)
        ..statutoryDiscountTypeId = 'sc'
        ..statutoryDiscountPct = 20
        ..statutoryIdNumber = 'SC-123';
      expect(validate([l], cap: 5), isEmpty);
    });

    test('serialized items need a unique serial no.', () {
      final item = _item(serialized: true);
      expect(validate([_line(item)]), contains(contains('serial no. required')));
      final a = _line(item)..serialNo = 'SN1';
      final b = CartLine(key: 'b', item: item, qty: 1, unitPrice: 100, defaultWarehouseId: 'wh-1')..serialNo = 'SN1';
      expect(validate([a, b]), contains(contains('twice')));
    });

    test('stock is checked against cached on-hand minus unsynced sales', () {
      final item = _item();
      expect(validate([_line(item, qty: 5)], avail: {'i1': 4}), contains(contains('only 4 in stock')));
      expect(validate([_line(item, qty: 4)], avail: {'i1': 4}), isEmpty);
      expect(validate([_line(_item(allowNegative: true), qty: 5)], avail: {'i1': 0}), isEmpty);
    });

    test('stocked item without a default warehouse is refused', () {
      expect(validate([_line(_item(), wh: null)]), contains(contains('default warehouse')));
    });
  });

  group('tenders', () {
    test('change must come from one cash tender', () {
      expect(validateTenders([Tender(method: _method('CASH'), amount: 500)], 450), isEmpty);
      expect(validateTenders([Tender(method: _method('GCASH', needsRef: true), amount: 500, referenceNo: 'x')], 450),
          contains(contains('cash')));
    });

    test('short payment and missing reference no. are caught', () {
      expect(validateTenders([Tender(method: _method('CASH'), amount: 400)], 450), contains(contains('short')));
      expect(validateTenders([Tender(method: _method('CARD', needsRef: true), amount: 450)], 450),
          contains(contains('required')));
    });
  });

  test('checkout body matches CreatePosSaleCommand', () {
    final body = buildPosCheckoutBody(
      branchId: 'BR1',
      posTerminalId: 't1',
      customerId: null,
      soldAt: DateTime.utc(2026, 10, 10, 1, 30),
      headerDiscountPct: 0,
      lines: [_line(_item(), qty: 2, price: 50)],
      tenders: [Tender(method: _method('CASH'), amount: 100)],
      userId: 'u1',
    );
    expect(body['invoiceDate'], '2026-10-10T01:30:00.000Z');
    expect(body['discountPct'], isNull);
    final line = (body['lines'] as List).single as Map;
    expect(line, containsPair('vatType', 'VATABLE'));
    expect(line, containsPair('uomId', 'uom-1'));
    expect((body['tenders'] as List).single, containsPair('paymentMethodId', 'pm-CASH'));
    expect(body.containsKey('meta'), isFalse);
  });
}
