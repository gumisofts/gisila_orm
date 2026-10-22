/// Small string helpers for safe SQL identifier and literal quoting.
library gisila.database.extensions;

extension SafeString on String {
  /// Wrap as a quoted SQL identifier (`"foo"`). Inner double quotes are
  /// escaped by doubling. Idempotent only for an already well-formed
  /// quoted identifier, so `x" , (SELECT ...) AS "y` cannot break out.
  String get safeTk {
    if (_isWrapped(this, '"')) return this;
    return '"${replaceAll('"', '""')}"';
  }

  /// Wrap as a single-quoted SQL string literal. Inner single quotes are
  /// escaped by doubling per the SQL standard. Idempotent only for an
  /// already well-formed literal.
  String get safe {
    if (_isWrapped(this, "'")) return this;
    return "'${replaceAll("'", "''")}'";
  }
}

/// True when [s] is wrapped in [q] and every inner [q] is doubled, i.e.
/// it is already a complete, correctly escaped token.
bool _isWrapped(String s, String q) {
  if (s.length < 2 || !s.startsWith(q) || !s.endsWith(q)) return false;
  return !s.substring(1, s.length - 1).replaceAll('$q$q', '').contains(q);
}
