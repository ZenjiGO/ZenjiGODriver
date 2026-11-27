import 'package:flutter/services.dart';

/// Shared number / date formatting so every screen shows money the same way.
class Fmt {
  Fmt._();

  /// 40030.4 -> "40,030.40", 24423 -> "24,423". Whole amounts drop the decimals.
  static String money(num? v, {bool forceDecimals = false}) {
    final n = (v ?? 0);
    final neg = n < 0;
    final abs = n.abs();
    final whole = abs == abs.roundToDouble();
    final fixed = abs.toStringAsFixed(whole && !forceDecimals ? 0 : 2);
    final parts = fixed.split('.');
    final digits = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    final out = parts.length > 1 ? '${buf.toString()}.${parts[1]}' : buf.toString();
    return neg ? '-$out' : out;
  }

  /// "TZS 40,030.40"
  static String tzs(num? v, {bool forceDecimals = false}) => 'TZS ${money(v, forceDecimals: forceDecimals)}';

  /// Parses anything numeric-looking (also "1,200.50") to a number.
  static num parse(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v;
    return num.tryParse(v.toString().replaceAll(',', '').trim()) ?? 0;
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static DateTime? _dt(dynamic v) {
    if (v == null) return null;
    final d = DateTime.tryParse(v.toString());
    if (d == null) return null;
    return d.isUtc ? d.toLocal() : d;
  }

  /// "27 Oct 2026"
  static String date(dynamic v) {
    final d = _dt(v);
    if (d == null) return v == null ? '—' : v.toString();
    return '${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  /// "27 Oct 2026 · 14:05"
  static String dateTime(dynamic v) {
    final d = _dt(v);
    if (d == null) return v == null ? '—' : v.toString();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${_months[d.month - 1]} ${d.year} · $hh:$mm';
  }

  /// "Today", "Yesterday" or "27 Oct 2026".
  static String dayLabel(dynamic v, {String today = 'Today', String yesterday = 'Yesterday'}) {
    final d = _dt(v);
    if (d == null) return v == null ? '—' : v.toString();
    final now = DateTime.now();
    final a = DateTime(d.year, d.month, d.day);
    final b = DateTime(now.year, now.month, now.day);
    final diff = b.difference(a).inDays;
    if (diff == 0) return today;
    if (diff == 1) return yesterday;
    return date(v);
  }
}

/// Adds thousands separators while the driver types an amount (e.g. 12000 -> 12,000).
class ThousandsInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final cleaned = newValue.text.replaceAll(RegExp(r'[^0-9.]'), '');
    final firstDot = cleaned.indexOf('.');
    String intPart = firstDot == -1 ? cleaned : cleaned.substring(0, firstDot);
    String decPart = firstDot == -1 ? '' : cleaned.substring(firstDot + 1).replaceAll('.', '');
    if (decPart.length > 2) decPart = decPart.substring(0, 2);
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    var text = buf.toString();
    if (firstDot != -1) text = '$text.$decPart';
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
