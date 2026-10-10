import 'dart:convert';

/// Minimal ESC/POS byte builder — the command subset every 58/80 mm thermal printer understands (Bluetooth
/// "InnerPrinter" built-ins included): initialise, alignment, bold, double size, text, feed, cut.
enum PrintAlign { left, center, right }

class PrintLine {
  const PrintLine(this.text, {this.align = PrintAlign.left, this.bold = false, this.big = false});

  final String text;
  final PrintAlign align;
  final bool bold;

  /// Double width + height. Halves the characters that fit on a line.
  final bool big;
}

class EscPos {
  final List<int> _bytes = [];

  List<int> get bytes => List.unmodifiable(_bytes);

  EscPos init() => _add([0x1B, 0x40]);

  EscPos align(PrintAlign a) => _add([0x1B, 0x61, a.index]);

  EscPos bold(bool on) => _add([0x1B, 0x45, on ? 1 : 0]);

  EscPos big(bool on) => _add([0x1D, 0x21, on ? 0x11 : 0x00]);

  EscPos text(String s) => _add([...latin1.encode(sanitize(s)), 0x0A]);

  EscPos feed(int lines) => _add([0x1B, 0x64, lines]);

  /// Partial cut with a short feed; printers without a cutter ignore it.
  EscPos cut() => _add([0x1D, 0x56, 0x42, 0x00]);

  EscPos line(PrintLine l) {
    align(l.align);
    if (l.bold) bold(true);
    if (l.big) big(true);
    text(l.text);
    if (l.big) big(false);
    if (l.bold) bold(false);
    return this;
  }

  EscPos _add(List<int> b) {
    _bytes.addAll(b);
    return this;
  }

  /// Thermal printers use a single-byte code page: keep printable Latin-1 and spell out the peso sign.
  static String sanitize(String s) {
    final buffer = StringBuffer();
    for (final rune in s.replaceAll('₱', 'P').runes) {
      buffer.writeCharCode(rune >= 0x20 && rune <= 0xFF ? rune : 0x3F); // '?'
    }
    return buffer.toString();
  }

  static List<int> render(List<PrintLine> lines, {int feedAfter = 3}) {
    final p = EscPos().init();
    for (final l in lines) {
      p.line(l);
    }
    return (p..feed(feedAfter)..cut()).bytes;
  }
}

/// Text layout helpers for a fixed character width.
abstract final class Cols {
  static String rule(int width, [String ch = '-']) => ch * width;

  /// Left text and right text on one line (the left is cut to make room).
  static String row(String left, String right, int width) {
    final room = width - right.length - 1;
    final l = left.length > room ? left.substring(0, room < 0 ? 0 : room) : left;
    return '$l${' ' * (width - l.length - right.length).clamp(1, width)}$right';
  }

  /// Word-wraps to [width]; long words are broken.
  static List<String> wrap(String text, int width) {
    final out = <String>[];
    var current = '';
    for (final word in text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      var w = word;
      while (w.length > width) {
        if (current.isNotEmpty) {
          out.add(current);
          current = '';
        }
        out.add(w.substring(0, width));
        w = w.substring(width);
      }
      if (current.isEmpty) {
        current = w;
      } else if (current.length + 1 + w.length <= width) {
        current = '$current $w';
      } else {
        out.add(current);
        current = w;
      }
    }
    if (current.isNotEmpty) out.add(current);
    return out.isEmpty ? [''] : out;
  }
}
