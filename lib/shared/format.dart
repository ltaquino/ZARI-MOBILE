import 'package:intl/intl.dart';

final _money = NumberFormat.currency(locale: 'en_PH', symbol: '₱', decimalDigits: 2);
final _qty = NumberFormat('#,##0.####');
final _dateTime = DateFormat('MMM d, y h:mm a');
final _date = DateFormat('MMM d, y');

String money(num? v) => v == null ? '—' : _money.format(v);
String qty(num v) => _qty.format(v);
String dateTime(DateTime d) => _dateTime.format(d.toLocal());
String date(DateTime d) => _date.format(d.toLocal());

String ago(DateTime? d) {
  if (d == null) return 'never';
  final diff = DateTime.now().difference(d.toLocal());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${diff.inDays} d ago';
}

/// Lenient numeric parse for text fields ("1,250.50" → 1250.5).
double? parseNum(String s) => double.tryParse(s.replaceAll(',', '').trim());
