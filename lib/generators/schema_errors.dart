/// Diagnostics for the gisila schema parser/validator.
///
/// Every problem detected when loading a `*.gisila.yaml` file is
/// captured as a [SchemaError] with a [SourceSpan] pointing at the
/// offending YAML node. A run accumulates all errors before throwing
/// a single [SchemaValidationException], so a user editing their
/// schema sees every mistake at once instead of one-per-rebuild.
///
/// The exception's [SchemaValidationException.format] method renders
/// `rustc`-style diagnostics with line numbers, an arrow under the
/// bad token, ANSI colors (when supported), and an optional hint:
///
/// ```text
/// error[unknown_type]: unknown column type 'varchars'
///   --> lib/models/blog.gisila.yaml:5:13
///    |
///  5 |       type: varchars
///    |             ^^^^^^^^ expected one of: varchar, text, integer, ...
///    |
///    = help: did you mean 'varchar'?
/// ```
library gisila.generators.schema_errors;

import 'dart:io';
import 'dart:math' as math;

import 'package:source_span/source_span.dart';

/// Severity of a single [SchemaError].
enum SchemaErrorLevel {
  error,
  warning;

  String get label => switch (this) {
        SchemaErrorLevel.error => 'error',
        SchemaErrorLevel.warning => 'warning',
      };
}

/// One diagnostic produced by the schema validator.
///
/// Always carries a [SourceSpan] so the formatter can render the
/// exact line and column inside the source `*.gisila.yaml` file.
class SchemaError {
  SchemaError({
    required this.code,
    required this.message,
    required this.span,
    this.level = SchemaErrorLevel.error,
    this.hint,
    this.notes = const [],
  });

  /// Stable short identifier (`unknown_type`, `missing_field`, ...).
  /// Surfaces in the rendered banner as `error[<code>]:` so users can
  /// grep / search the docs for it.
  final String code;

  /// Human-readable headline shown next to the severity.
  final String message;

  /// Primary location the error refers to. Renderer underlines the
  /// span and uses its `sourceUrl` for the `--> path:line:col` header.
  final SourceSpan span;

  /// `error` or `warning`. Only `error` aborts the build.
  final SchemaErrorLevel level;

  /// Optional one-liner suggestion (`did you mean 'varchar'?`).
  final String? hint;

  /// Extra notes printed beneath the snippet (one bullet per entry).
  final List<String> notes;
}

/// Thrown by the schema parser/validator when one or more
/// [SchemaError]s were detected. Carries every accumulated error so
/// the build_runner builder can render them all at once.
class SchemaValidationException implements Exception {
  SchemaValidationException(this.errors)
      : assert(errors.isNotEmpty, 'must contain at least one error');

  final List<SchemaError> errors;

  /// True if at least one diagnostic is at error severity.
  bool get hasErrors => errors.any((e) => e.level == SchemaErrorLevel.error);

  /// Render every diagnostic with optional ANSI colors. When [color]
  /// is null, auto-detects via [stdout.supportsAnsiEscapes] and the
  /// `NO_COLOR` environment variable.
  String format({bool? color}) {
    final useColor = color ?? _ansiSupported();
    final sty = _AnsiStyles(useColor);
    final buf = StringBuffer();
    for (var i = 0; i < errors.length; i++) {
      buf.write(_formatOne(errors[i], sty));
      if (i != errors.length - 1) buf.writeln();
    }
    final summary = _summary(errors);
    if (summary != null) {
      buf
        ..writeln()
        ..writeln(sty.bold(sty.red(summary)));
    }
    return buf.toString();
  }

  @override
  String toString() => format(color: false);
}

String _formatOne(SchemaError err, _AnsiStyles sty) {
  final buf = StringBuffer();
  final levelColor = err.level == SchemaErrorLevel.error ? sty.red : sty.yellow;
  final headerLeft = sty.bold(levelColor('${err.level.label}[${err.code}]'));
  buf.writeln('$headerLeft${sty.bold(': ${err.message}')}');

  final start = err.span.start;
  final url = start.sourceUrl?.toString() ?? '<unknown>';
  final line = start.line + 1;
  final col = start.column + 1;
  final gutter = ' ' * line.toString().length;

  buf.writeln(' ${sty.cyan('-->')} $url:$line:$col');
  buf.writeln(' $gutter ${sty.cyan('|')}');

  final snippet = _extractSnippetLine(err.span);
  buf.writeln(' ${sty.cyan(line.toString())} ${sty.cyan('|')} $snippet');

  final caret = _buildCaret(err.span, snippet);
  final caretText = err.hint == null
      ? sty.bold(levelColor(caret))
      : '${sty.bold(levelColor(caret))} ${levelColor(err.hint!)}';
  buf.writeln(' $gutter ${sty.cyan('|')} $caretText');

  for (final note in err.notes) {
    buf.writeln(' $gutter ${sty.cyan('|')}');
    buf.writeln(' $gutter ${sty.cyan('=')} ${sty.bold('note')}: $note');
  }
  if (err.hint != null && err.notes.isEmpty) {
    buf.writeln(' $gutter ${sty.cyan('|')}');
    buf.writeln(' $gutter ${sty.cyan('=')} ${sty.bold('help')}: ${err.hint}');
  }
  return buf.toString();
}

/// Pull the first line of source text that the span covers, falling
/// back to a synthesized "<source unavailable>" if the span has no
/// surrounding context (which `package:yaml` always provides, but
/// defensive code keeps the formatter robust).
String _extractSnippetLine(SourceSpan span) {
  if (span is SourceSpanWithContext) {
    final ctx = span.context;
    final firstNewline = ctx.indexOf('\n');
    return firstNewline == -1 ? ctx : ctx.substring(0, firstNewline);
  }
  // Best-effort fallback: use the span's own text on a single line.
  final text = span.text.split('\n').first;
  return text.isEmpty ? '<source unavailable>' : text;
}

/// Build `   ^^^^` underline for the span. The number of leading
/// spaces matches the span's start column inside the source line, and
/// the number of carets matches the visible width of the highlighted
/// token (clamped so it never overshoots the snippet).
String _buildCaret(SourceSpan span, String snippet) {
  // `SourceSpanWithContext.context` always begins at column 0 of the
  // line containing `start`, so the column from the span maps 1:1 to
  // the snippet we just extracted.
  var leading = span.start.column;
  if (leading < 0) leading = 0;
  // For multi-line spans clamp the underline length to the remainder
  // of the rendered snippet line.
  final remaining = snippet.length - leading;
  var width = math.max(1, span.length);
  if (remaining > 0 && width > remaining) width = remaining;
  return '${' ' * leading}${'^' * width}';
}

String? _summary(List<SchemaError> errors) {
  if (errors.isEmpty) return null;
  final errCount =
      errors.where((e) => e.level == SchemaErrorLevel.error).length;
  final warnCount = errors.length - errCount;
  if (errCount == 0 && warnCount == 0) return null;
  final parts = <String>[];
  if (errCount > 0) {
    parts.add('$errCount ${errCount == 1 ? "error" : "errors"}');
  }
  if (warnCount > 0) {
    parts.add('$warnCount ${warnCount == 1 ? "warning" : "warnings"}');
  }
  return 'aborting due to ${parts.join(", ")}';
}

bool _ansiSupported() {
  if (Platform.environment['NO_COLOR'] != null) return false;
  try {
    return stdout.supportsAnsiEscapes;
  } catch (_) {
    return false;
  }
}

/// ANSI color helpers. Public-but-underscored so the renderer in this
/// file can pass an instance around without exposing the type to
/// callers; the `color: bool?` knob on `format` is the supported API.
class _AnsiStyles {
  const _AnsiStyles(this.enabled);
  final bool enabled;

  String _wrap(String code, String text) =>
      enabled ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String s) => _wrap('1', s);
  String red(String s) => _wrap('31', s);
  String yellow(String s) => _wrap('33', s);
  String cyan(String s) => _wrap('36', s);
}

/// Suggest the closest match from [candidates] for [input] using
/// Damerau-Levenshtein distance. Returns null when nothing is within
/// `max(2, input.length / 2)` edits.
String? suggestClosest(String input, Iterable<String> candidates) {
  if (input.isEmpty) return null;
  final lower = input.toLowerCase();
  String? best;
  var bestDistance = 1 << 30;
  for (final cand in candidates) {
    final d = _levenshtein(lower, cand.toLowerCase());
    if (d < bestDistance) {
      bestDistance = d;
      best = cand;
    }
  }
  if (best == null) return null;
  final tolerance = math.max(2, input.length ~/ 2);
  return bestDistance <= tolerance ? best : null;
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final prev = List<int>.filled(b.length + 1, 0);
  final curr = List<int>.filled(b.length + 1, 0);
  for (var j = 0; j <= b.length; j++) {
    prev[j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    for (var j = 0; j <= b.length; j++) {
      prev[j] = curr[j];
    }
  }
  return prev[b.length];
}
