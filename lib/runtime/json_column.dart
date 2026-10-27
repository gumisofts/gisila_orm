/// Helpers generated models use for `json` / `jsonb` columns.
library gisila.runtime.json_column;

import 'dart:convert';

/// Encodes a `json` column's value for the database. The driver can only
/// bind a Dart `Map` (or number) as JSON on its own; arrays, strings and
/// booleans need the encoded text, which Postgres parses into the column.
String? encodeJsonColumn(Object? value) =>
    value == null ? null : jsonEncode(value);
