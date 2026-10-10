class FormPermission {
  const FormPermission({
    required this.formCode,
    this.canView = false,
    this.canCreate = false,
    this.canEdit = false,
    this.canApprove = false,
    this.canCancel = false,
    this.canDelete = false,
  });

  final String formCode;
  final bool canView;
  final bool canCreate;
  final bool canEdit;
  final bool canApprove;
  final bool canCancel;
  final bool canDelete;

  factory FormPermission.fromJson(Map<String, dynamic> j) => FormPermission(
        formCode: j['formCode'] as String,
        canView: j['canView'] == true,
        canCreate: j['canCreate'] == true,
        canEdit: j['canEdit'] == true,
        canApprove: j['canApprove'] == true,
        canCancel: j['canCancel'] == true,
        canDelete: j['canDelete'] == true,
      );

  Map<String, dynamic> toJson() => {
        'formCode': formCode,
        'canView': canView,
        'canCreate': canCreate,
        'canEdit': canEdit,
        'canApprove': canApprove,
        'canCancel': canCancel,
        'canDelete': canDelete,
      };
}

enum FormAction { view, create, edit, approve, cancel, delete }

/// ZARI form codes the mobile app gates on (seeded in AppDbSeeder).
abstract final class Forms {
  static const items = 'ITEMS';
  static const stockOpnames = 'STOCK_OPNAMES';
  static const stockAdjustments = 'STOCK_ADJUSTMENTS';
  static const salesOrders = 'SALES_ORDERS';
  static const posMode = 'POS_MODE';
  static const customers = 'CUSTOMERS';
}

/// The signed-in user as the app needs them offline: profile, branch
/// assignments and effective per-form permissions — fetched once at online
/// sign-in and cached, same as ZARI-FE's AuthContext.
class UserSession {
  const UserSession({
    required this.userId,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.roles,
    required this.branchIds,
    required this.permissions,
    required this.fetchedAt,
  });

  final String userId;
  final String email;
  final String firstName;
  final String lastName;
  final List<String> roles;
  final List<String> branchIds;
  final Map<String, FormPermission> permissions;
  final DateTime fetchedAt;

  String get displayName => '$firstName $lastName'.trim().isEmpty ? email : '$firstName $lastName'.trim();

  bool can(String formCode, FormAction action) {
    final p = permissions[formCode];
    if (p == null) return false;
    return switch (action) {
      FormAction.view => p.canView,
      FormAction.create => p.canCreate,
      FormAction.edit => p.canEdit,
      FormAction.approve => p.canApprove,
      FormAction.cancel => p.canCancel,
      FormAction.delete => p.canDelete,
    };
  }

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'email': email,
        'firstName': firstName,
        'lastName': lastName,
        'roles': roles,
        'branchIds': branchIds,
        'permissions': permissions.values.map((p) => p.toJson()).toList(),
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory UserSession.fromJson(Map<String, dynamic> j) => UserSession(
        userId: j['userId'] as String,
        email: j['email'] as String,
        firstName: (j['firstName'] as String?) ?? '',
        lastName: (j['lastName'] as String?) ?? '',
        roles: (j['roles'] as List).cast<String>(),
        branchIds: (j['branchIds'] as List).cast<String>(),
        permissions: {
          for (final p in (j['permissions'] as List).cast<Map<String, dynamic>>().map(FormPermission.fromJson)) p.formCode: p,
        },
        fetchedAt: DateTime.parse(j['fetchedAt'] as String),
      );
}
