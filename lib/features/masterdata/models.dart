import 'dart:convert';

/// Client-side mirrors of the ZARI DTOs the mobile app reads. Field names
/// follow the API's camelCase JSON (see ZARI-FE/src/types/index.ts).

double _num(dynamic v) => v == null ? 0 : (v as num).toDouble();
bool _bool(dynamic v) => v == true || v == 1;

enum VatType { vatable, vatExempt, zeroRated }

VatType parseVatType(String? raw) => switch (raw) {
      'VAT_EXEMPT' => VatType.vatExempt,
      'ZERO_RATED' => VatType.zeroRated,
      _ => VatType.vatable,
    };

String vatTypeCode(VatType v) => switch (v) {
      VatType.vatable => 'VATABLE',
      VatType.vatExempt => 'VAT_EXEMPT',
      VatType.zeroRated => 'ZERO_RATED',
    };

class Item {
  const Item({
    required this.id,
    required this.code,
    required this.name,
    this.description,
    this.categoryId,
    required this.baseUomId,
    this.itemType,
    required this.vatType,
    required this.status,
    required this.isSold,
    required this.isStocked,
    required this.isSerialized,
    required this.isBatchTracked,
    required this.allowNegativeStock,
  });

  final String id;
  final String code;
  final String name;
  final String? description;
  final String? categoryId;
  final String baseUomId;
  final String? itemType;
  final VatType vatType;
  final String status;
  final bool isSold;
  final bool isStocked;
  final bool isSerialized;
  final bool isBatchTracked;
  final bool allowNegativeStock;

  bool get isActive => status.toLowerCase() == 'active';

  factory Item.fromApi(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        categoryId: j['categoryId'] as String?,
        baseUomId: j['baseUomId'] as String,
        itemType: j['itemType'] as String?,
        vatType: parseVatType(j['vatType'] as String?),
        status: (j['status'] as String?) ?? 'active',
        isSold: _bool(j['isSold']),
        isStocked: _bool(j['isStocked']),
        isSerialized: _bool(j['isSerialized']),
        isBatchTracked: _bool(j['isBatchTracked']),
        allowNegativeStock: _bool(j['allowNegativeStock']),
      );

  factory Item.fromRow(Map<String, Object?> r) => Item(
        id: r['id'] as String,
        code: r['code'] as String,
        name: r['name'] as String,
        description: r['description'] as String?,
        categoryId: r['category_id'] as String?,
        baseUomId: r['base_uom_id'] as String,
        itemType: r['item_type'] as String?,
        vatType: parseVatType(r['vat_type'] as String?),
        status: r['status'] as String,
        isSold: _bool(r['is_sold']),
        isStocked: _bool(r['is_stocked']),
        isSerialized: _bool(r['is_serialized']),
        isBatchTracked: _bool(r['is_batch_tracked']),
        allowNegativeStock: _bool(r['allow_negative_stock']),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'code': code,
        'name': name,
        'description': description,
        'category_id': categoryId,
        'base_uom_id': baseUomId,
        'item_type': itemType,
        'vat_type': vatTypeCode(vatType),
        'status': status,
        'is_sold': isSold ? 1 : 0,
        'is_stocked': isStocked ? 1 : 0,
        'is_serialized': isSerialized ? 1 : 0,
        'is_batch_tracked': isBatchTracked ? 1 : 0,
        'allow_negative_stock': allowNegativeStock ? 1 : 0,
      };
}

class ItemBranchSetting {
  const ItemBranchSetting({
    required this.id,
    required this.itemId,
    required this.branchId,
    this.defaultWarehouseId,
    this.sellingPrice,
    required this.status,
  });

  final String id;
  final String itemId;
  final String branchId;
  final String? defaultWarehouseId;
  final double? sellingPrice;
  final String status;

  bool get isActive => status.toLowerCase() == 'active';

  factory ItemBranchSetting.fromApi(Map<String, dynamic> j) => ItemBranchSetting(
        id: j['id'] as String,
        itemId: j['itemId'] as String,
        branchId: j['branchId'] as String,
        defaultWarehouseId: j['defaultWarehouseId'] as String?,
        sellingPrice: j['sellingPrice'] == null ? null : _num(j['sellingPrice']),
        status: (j['status'] as String?) ?? 'active',
      );

  factory ItemBranchSetting.fromRow(Map<String, Object?> r) => ItemBranchSetting(
        id: r['id'] as String,
        itemId: r['item_id'] as String,
        branchId: r['branch_id'] as String,
        defaultWarehouseId: r['default_warehouse_id'] as String?,
        sellingPrice: r['selling_price'] == null ? null : _num(r['selling_price']),
        status: r['status'] as String,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'item_id': itemId,
        'branch_id': branchId,
        'default_warehouse_id': defaultWarehouseId,
        'selling_price': sellingPrice,
        'status': status,
      };
}

class StockBalance {
  const StockBalance({
    required this.id,
    required this.itemId,
    required this.branchId,
    required this.warehouseId,
    this.batchNo,
    required this.qtyOnHand,
    required this.avgUnitCost,
    this.lastMovementDate,
  });

  final String id;
  final String itemId;
  final String branchId;
  final String warehouseId;
  final String? batchNo;
  final double qtyOnHand;
  final double avgUnitCost;
  final String? lastMovementDate;

  factory StockBalance.fromApi(Map<String, dynamic> j) => StockBalance(
        id: j['id'] as String,
        itemId: j['itemId'] as String,
        branchId: j['branchId'] as String,
        warehouseId: j['warehouseId'] as String,
        batchNo: j['batchNo'] as String?,
        qtyOnHand: _num(j['qtyOnHand']),
        avgUnitCost: _num(j['avgUnitCost']),
        lastMovementDate: j['lastMovementDate'] as String?,
      );

  factory StockBalance.fromRow(Map<String, Object?> r) => StockBalance(
        id: r['id'] as String,
        itemId: r['item_id'] as String,
        branchId: r['branch_id'] as String,
        warehouseId: r['warehouse_id'] as String,
        batchNo: r['batch_no'] as String?,
        qtyOnHand: _num(r['qty_on_hand']),
        avgUnitCost: _num(r['avg_unit_cost']),
        lastMovementDate: r['last_movement_date'] as String?,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'item_id': itemId,
        'branch_id': branchId,
        'warehouse_id': warehouseId,
        'batch_no': batchNo,
        'qty_on_hand': qtyOnHand,
        'avg_unit_cost': avgUnitCost,
        'last_movement_date': lastMovementDate,
      };
}

/// A row from the generic `ref_data` table: the raw API JSON plus the handful
/// of columns the app filters/sorts on.
class RefRecord {
  const RefRecord(this.entity, this.json);

  final String entity;
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get code => (json['code'] as String?) ?? '';
  String get name => (json['name'] as String?) ?? (json['description'] as String?) ?? code;
  String? get branchId => json['branchId'] as String?;
  String get status => ((json['status'] as String?) ?? 'active').toLowerCase();
  bool get isActive => status == 'active';

  double numField(String key) => _num(json[key]);
  bool boolField(String key) => _bool(json[key]);
  String? strField(String key) => json[key] as String?;

  factory RefRecord.fromRow(Map<String, Object?> r) =>
      RefRecord(r['entity'] as String, jsonDecode(r['json'] as String) as Map<String, dynamic>);
}

/// Entity keys used in `ref_data`.
abstract final class RefEntity {
  static const branch = 'branch';
  static const warehouse = 'warehouse';
  static const uom = 'uom';
  static const customer = 'customer';
  static const paymentMethod = 'payment_method';
  static const posTerminal = 'pos_terminal';
  static const statutoryDiscountType = 'statutory_discount_type';
  static const adjustmentReason = 'adjustment_reason';
  static const company = 'company';
}
