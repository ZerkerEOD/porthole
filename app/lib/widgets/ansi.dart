/// Minimal ANSI SGR parser that turns a captured tmux line into TextSpans.
library;

import 'package:flutter/material.dart';

const _basic = <Color>[
  Color(0xFF000000), Color(0xFFCC3333), Color(0xFF33AA33), Color(0xFFAAAA33),
  Color(0xFF3366CC), Color(0xFFAA33AA), Color(0xFF33AAAA), Color(0xFFCCCCCC),
  Color(0xFF666666), Color(0xFFFF6666), Color(0xFF66DD66), Color(0xFFDDDD66),
  Color(0xFF6699FF), Color(0xFFDD66DD), Color(0xFF66DDDD), Color(0xFFFFFFFF),
];

Color _xterm256(int n) {
  if (n < 16) return _basic[n];
  if (n < 232) {
    final i = n - 16;
    final r = i ~/ 36, g = (i % 36) ~/ 6, b = i % 6;
    int lvl(int v) => v == 0 ? 0 : 55 + v * 40;
    return Color.fromARGB(255, lvl(r), lvl(g), lvl(b));
  }
  final v = 8 + (n - 232) * 10;
  return Color.fromARGB(255, v, v, v);
}

class _Sgr {
  Color? fg, bg;
  bool bold = false, dim = false, italic = false, underline = false, reverse = false, strike = false;
  _Sgr copy() => _Sgr()
    ..fg = fg
    ..bg = bg
    ..bold = bold
    ..dim = dim
    ..italic = italic
    ..underline = underline
    ..reverse = reverse
    ..strike = strike;
}

/// Parses one line. [base] supplies the default colours.
TextSpan ansiToSpan(String line, TextStyle base) {
  final spans = <TextSpan>[];
  var st = _Sgr();
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    var fg = st.fg ?? base.color;
    var bg = st.bg;
    if (st.reverse) {
      final t = fg;
      fg = bg ?? base.backgroundColor ?? Colors.black;
      bg = t;
    }
    if (st.dim && fg != null) fg = fg.withValues(alpha: 0.6);
    spans.add(TextSpan(
      text: buf.toString(),
      style: base.copyWith(
        color: fg,
        backgroundColor: bg,
        fontWeight: st.bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: st.italic ? FontStyle.italic : FontStyle.normal,
        decoration: TextDecoration.combine([
          if (st.underline) TextDecoration.underline,
          if (st.strike) TextDecoration.lineThrough,
        ]),
      ),
    ));
    buf.clear();
  }

  var i = 0;
  while (i < line.length) {
    final c = line.codeUnitAt(i);
    if (c == 0x1b && i + 1 < line.length && line[i + 1] == '[') {
      final end = line.indexOf(RegExp(r'[A-Za-z]'), i + 2);
      if (end < 0) break;
      final cmd = line[end];
      final params = line.substring(i + 2, end);
      i = end + 1;
      if (cmd != 'm') continue; // ignore cursor movement etc.
      flush();
      final ps = params.isEmpty ? [0] : params.split(';').map((s) => int.tryParse(s) ?? 0).toList();
      var k = 0;
      while (k < ps.length) {
        final p = ps[k];
        switch (p) {
          case 0:
            st = _Sgr();
          case 1:
            st.bold = true;
          case 2:
            st.dim = true;
          case 3:
            st.italic = true;
          case 4:
            st.underline = true;
          case 7:
            st.reverse = true;
          case 9:
            st.strike = true;
          case 22:
            st.bold = false;
            st.dim = false;
          case 23:
            st.italic = false;
          case 24:
            st.underline = false;
          case 27:
            st.reverse = false;
          case 29:
            st.strike = false;
          case 39:
            st.fg = null;
          case 49:
            st.bg = null;
          case 38 || 48:
            final isFg = p == 38;
            if (k + 1 < ps.length && ps[k + 1] == 5 && k + 2 < ps.length) {
              final col = _xterm256(ps[k + 2].clamp(0, 255));
              if (isFg) {
                st.fg = col;
              } else {
                st.bg = col;
              }
              k += 2;
            } else if (k + 1 < ps.length && ps[k + 1] == 2 && k + 4 < ps.length) {
              final col = Color.fromARGB(255, ps[k + 2].clamp(0, 255), ps[k + 3].clamp(0, 255), ps[k + 4].clamp(0, 255));
              if (isFg) {
                st.fg = col;
              } else {
                st.bg = col;
              }
              k += 4;
            }
          default:
            if (p >= 30 && p <= 37) st.fg = _basic[p - 30];
            if (p >= 40 && p <= 47) st.bg = _basic[p - 40];
            if (p >= 90 && p <= 97) st.fg = _basic[p - 90 + 8];
            if (p >= 100 && p <= 107) st.bg = _basic[p - 100 + 8];
        }
        k++;
      }
      continue;
    }
    if (c == 0x1b) {
      // Other escape (OSC etc.): skip to a terminator.
      final end = line.indexOf(RegExp(r'[\x07\\]'), i + 1);
      i = end < 0 ? line.length : end + 1;
      continue;
    }
    buf.writeCharCode(c);
    i++;
  }
  flush();
  return TextSpan(children: spans, style: base);
}
