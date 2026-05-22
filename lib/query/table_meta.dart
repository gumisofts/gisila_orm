/// Static schema metadata that codegen attaches to each model.
library gisila.query.table_meta;

import 'package:gisila_orm/query/hydrator.dart';

/// Static metadata that codegen attaches to each model. Carried inside
/// `Query<T>` so the runtime knows what table to talk to and how to
/// hydrate result rows.
class TableMeta<T> {
  /// SQL table name (unquoted).
  final String tableName;

  /// Name of the primary-key column (defaults to `id`).
  final String primaryKey;

  /// All non-relation column names, in canonical order. Used as the
  /// default projection.
  final List<String> columnNames;

  /// Function that materialises one row into a `T`.
  final RowMapper<T> fromRow;

  const TableMeta({
    required this.tableName,
    required this.columnNames,
    required this.fromRow,
    this.primaryKey = 'id',
  });
}
