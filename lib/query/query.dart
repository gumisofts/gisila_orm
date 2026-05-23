/// `Query<T>` - the canonical fluent query builder for gisila.
///
/// Every read and write goes through this class. Where clauses are
/// expressed with the typed [Expr] AST, mutations use a small set of
/// builders (`InsertQuery`, `UpdateQuery`, `DeleteQuery`), and the
/// SQL is always emitted via [SqlCompiler] using `$n` placeholders.
///
/// ```dart
/// final users = await Query<User>(UserTable.metadata)
///     .where((u) => u.email.like('%@gumi.com'))
///     .orderBy(UserTable.createdAt, desc: true)
///     .limit(50)
///     .all(db);
/// ```
library gisila.query.query;

import 'package:gisila_orm/database/extensions.dart';
import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';
import 'package:gisila_orm/query/compiler.dart';
import 'package:gisila_orm/query/expression.dart';
import 'package:gisila_orm/query/hydrator.dart';
import 'package:gisila_orm/query/preloader.dart';
import 'package:gisila_orm/query/relation.dart';
import 'package:gisila_orm/query/table_meta.dart';
import 'package:gisila_orm/runtime/db_context.dart';

export 'package:gisila_orm/query/compiler.dart' show CompiledSql, SqlCompiler;
export 'package:gisila_orm/query/expression.dart';
export 'package:gisila_orm/query/hydrator.dart' show Hydrator, RowMapper;
export 'package:gisila_orm/query/preloader.dart' show Preloader;
export 'package:gisila_orm/query/relation.dart';
export 'package:gisila_orm/query/table_meta.dart';

/// Direction for `ORDER BY`.
enum SortOrder { asc, desc }

/// Single ORDER BY entry.
///
/// Holds an arbitrary [Expr] (not just a [ColumnRef]) so we can sort by
/// computed expressions such as pgvector distance operators:
/// `ORDER BY embedding <=> $1::vector`.
class OrderTerm {
  final Expr<dynamic> expr;
  final SortOrder order;
  final bool nullsFirst;

  const OrderTerm(this.expr,
      {this.order = SortOrder.asc, this.nullsFirst = false});
}

/// Join descriptor.
enum JoinType { inner, left, right, full }

class JoinSpec {
  final JoinType type;
  final String table;
  final String? alias;
  final Expr<bool> on;
  const JoinSpec(this.type, this.table, this.on, {this.alias});

  String get keyword => switch (type) {
        JoinType.inner => 'INNER JOIN',
        JoinType.left => 'LEFT JOIN',
        JoinType.right => 'RIGHT JOIN',
        JoinType.full => 'FULL OUTER JOIN',
      };
}

/// SELECT-side fluent builder.
class Query<T> {
  final TableMeta<T> _meta;

  Expr<bool>? _where;
  final List<OrderTerm> _orderBy = [];
  final List<JoinSpec> _joins = [];
  final List<ColumnRef<dynamic>> _groupBy = [];
  Expr<bool>? _having;
  bool _distinct = false;
  int? _limit;
  int? _offset;
  List<String>? _projection;
  final List<Relation<dynamic, dynamic>> _preloads = [];

  Query(this._meta);

  // Fluent operations ----------------------------------------------------

  /// Restrict rows. Multiple calls are AND-ed together.
  Query<T> where(Expr<bool> predicate) {
    _where = _where == null ? predicate : _where!.and(predicate);
    return this;
  }

  /// Add an ORDER BY entry. [expr] is typically a [ColumnRef] but any
  /// [Expr] is accepted, which is what makes
  /// `orderBy(embedding.cosineDistance(query))` work for nearest-neighbour
  /// search.
  Query<T> orderBy(Expr<dynamic> expr,
      {bool desc = false, bool nullsFirst = false}) {
    _orderBy.add(OrderTerm(expr,
        order: desc ? SortOrder.desc : SortOrder.asc, nullsFirst: nullsFirst));
    return this;
  }

  Query<T> limit(int n) {
    _limit = n;
    return this;
  }

  Query<T> offset(int n) {
    _offset = n;
    return this;
  }

  Query<T> distinct() {
    _distinct = true;
    return this;
  }

  Query<T> groupBy(ColumnRef<dynamic> column) {
    _groupBy.add(column);
    return this;
  }

  Query<T> having(Expr<bool> predicate) {
    _having = predicate;
    return this;
  }

  Query<T> join(String table, Expr<bool> on,
      {JoinType type = JoinType.inner, String? alias}) {
    _joins.add(JoinSpec(type, table, on, alias: alias));
    return this;
  }

  /// Project a subset of columns. Useful for `SELECT col1, col2 FROM ...`.
  /// The result still hydrates via the model `fromRow`, so unselected
  /// fields will fall back to defaults defined on the model.
  Query<T> select(List<String> columns) {
    _projection = List.unmodifiable(columns);
    return this;
  }

  /// Schedule a relation tree for batched eager loading.
  Query<T> preload(List<Relation<dynamic, dynamic>> relations) {
    _preloads.addAll(relations);
    return this;
  }

  // SQL emission ---------------------------------------------------------

  /// Compile this query into final SQL + parameters.
  CompiledSql compile({String? overrideSelect}) {
    final c = SqlCompiler();
    final buf = StringBuffer('SELECT ');
    if (_distinct) buf.write('DISTINCT ');

    if (overrideSelect != null) {
      buf.write(overrideSelect);
    } else {
      final cols = _projection ?? _meta.columnNames;
      buf.write(cols
          .map((col) => '${_meta.tableName.safeTk}.${col.safeTk}')
          .join(', '));
    }

    buf.write(' FROM ${_meta.tableName.safeTk}');

    for (final j in _joins) {
      final tbl = j.alias == null
          ? j.table.safeTk
          : '${j.table.safeTk} AS ${j.alias!.safeTk}';
      buf.write(' ${j.keyword} $tbl ON ${c.compile(j.on)}');
    }

    if (_where != null) {
      buf.write(' WHERE ${c.compile(_where!)}');
    }

    if (_groupBy.isNotEmpty) {
      buf.write(' GROUP BY ');
      buf.write(_groupBy.map(c.visitColumnRef).join(', '));
    }

    if (_having != null) {
      buf.write(' HAVING ${c.compile(_having!)}');
    }

    if (_orderBy.isNotEmpty) {
      buf.write(' ORDER BY ');
      buf.write(_orderBy.map((t) {
        final dir = t.order == SortOrder.asc ? 'ASC' : 'DESC';
        final nulls = t.nullsFirst ? ' NULLS FIRST' : '';
        return '${c.compile(t.expr)} $dir$nulls';
      }).join(', '));
    }

    if (_limit != null) buf.write(' LIMIT ${_limit!}');
    if (_offset != null) buf.write(' OFFSET ${_offset!}');

    return CompiledSql(buf.toString(), c.params);
  }

  // Terminal operations --------------------------------------------------

  /// Execute and return all matching rows hydrated as `List<T>`.
  ///
  /// If any [preload] relations were registered, a [Preloader] runs
  /// after hydration, issuing one batched `WHERE fk IN (...)` query
  /// per relation level and stitching results back onto each parent.
  Future<List<T>> all(DbContext db) async {
    final compiled = compile();
    final result = await db.execute(compiled.sql, parameters: compiled.params);
    final rows = Hydrator<T>(_meta.fromRow).hydrateAll(result);
    if (_preloads.isNotEmpty && rows.isNotEmpty) {
      await Preloader().applyTo(rows.cast<Object>(), _preloads, db);
    }
    return rows;
  }

  /// Return exactly one row. Throws [QueryNoRowsException] or
  /// [QueryMultipleRowsException] if zero or more than one row matches.
  Future<T> one(DbContext db) async {
    final rows = await limit(2).all(db);
    if (rows.isEmpty) {
      throw QueryNoRowsException('Query<$T>.one() found no rows');
    }
    if (rows.length > 1) {
      throw QueryMultipleRowsException('Query<$T>.one() found multiple rows');
    }
    return rows.single;
  }

  /// Return the first row matching, or null.
  Future<T?> first(DbContext db) async {
    final rows = await limit(1).all(db);
    return rows.isEmpty ? null : rows.first;
  }

  /// `SELECT COUNT(*)` honoring the current WHERE/JOINs.
  Future<int> count(DbContext db) async {
    final compiled = compile(overrideSelect: 'COUNT(*)::bigint AS "count"');
    final result = await db.execute(compiled.sql, parameters: compiled.params);
    final row = result.first.toColumnMap();
    return (row['count'] as num).toInt();
  }

  /// `SELECT EXISTS(...)`.
  Future<bool> exists(DbContext db) async {
    final inner = compile(overrideSelect: '1');
    final sql = 'SELECT EXISTS(${inner.sql}) AS "exists"';
    final result = await db.execute(sql, parameters: inner.params);
    return result.first.toColumnMap()['exists'] as bool;
  }

  /// Stream rows lazily (uses [DbContext.stream]).
  Stream<T> stream(DbContext db) async* {
    final compiled = compile();
    final hydrator = Hydrator<T>(_meta.fromRow);
    await for (final row
        in db.stream(compiled.sql, parameters: compiled.params)) {
      yield hydrator.hydrateOne(row);
    }
  }

  // Mutation entry points ------------------------------------------------

  /// Begin an `INSERT INTO _table_ (...) VALUES (...) RETURNING *`.
  InsertQuery<T> insert(Map<String, Object?> values) =>
      InsertQuery<T>._(_meta, values);

  /// Begin an `UPDATE _table_ SET ... [WHERE ...] RETURNING *`.
  /// The WHERE clause from this `Query<T>` is reused.
  UpdateQuery<T> update(Map<String, Object?> values) =>
      UpdateQuery<T>._(_meta, values, _where);

  /// Begin a `DELETE FROM _table_ [WHERE ...] RETURNING *`. Reuses the
  /// WHERE clause from this query.
  DeleteQuery<T> delete() => DeleteQuery<T>._(_meta, _where);
}

// ---------------------------------------------------------------------------
// Mutation builders
// ---------------------------------------------------------------------------

/// `INSERT` builder. Use [returning] (default true) to receive the new
/// row(s) back as `T` values.
class InsertQuery<T> {
  final TableMeta<T> _meta;
  final List<Map<String, Object?>> _rows;
  bool _returning = true;
  Expr<bool>? _onConflictDoNothing;

  InsertQuery._(this._meta, Map<String, Object?> first)
      : _rows = [Map.of(first)];

  /// Add another row for a multi-row INSERT.
  InsertQuery<T> values(Map<String, Object?> row) {
    _rows.add(Map.of(row));
    return this;
  }

  /// Toggle `RETURNING *` (defaults to true).
  InsertQuery<T> returning([bool enabled = true]) {
    _returning = enabled;
    return this;
  }

  /// `ON CONFLICT DO NOTHING`. The optional [target] is a SQL fragment
  /// like `(email)` describing the conflict target.
  InsertQuery<T> onConflictDoNothing() {
    _onConflictDoNothing = const RawSql<bool>('');
    return this;
  }

  CompiledSql compile() {
    if (_rows.isEmpty) {
      throw InvalidQueryBuilderException('InsertQuery<$T> has no rows');
    }
    // Normalize camelCase keys to snake_case so callers that accidentally
    // pass e.g. 'createdAt' still produce valid SQL.
    final normalized = _rows.map(_normalizeKeys).toList();
    final columns = normalized.first.keys.toList();
    if (normalized.any(
        (r) => r.length != columns.length || !columns.every(r.containsKey))) {
      throw ArgumentError('All inserted rows must use the same column set');
    }

    final c = SqlCompiler();
    final colsSql = columns.map((s) => s.safeTk).join(', ');
    final valuesSql = normalized.map((row) {
      final placeholders = columns.map((col) => c.bind(row[col])).join(', ');
      return '($placeholders)';
    }).join(', ');

    final buf = StringBuffer(
      'INSERT INTO ${_meta.tableName.safeTk} ($colsSql) VALUES $valuesSql',
    );
    if (_onConflictDoNothing != null) {
      buf.write(' ON CONFLICT DO NOTHING');
    }
    if (_returning) {
      buf.write(' RETURNING *');
    }

    return CompiledSql(buf.toString(), c.params);
  }

  /// Execute and return the inserted row(s), hydrated.
  Future<List<T>> run(DbContext db) async {
    final compiled = compile();
    final result = await db.execute(compiled.sql, parameters: compiled.params);
    if (!_returning) return const [];
    return Hydrator<T>(_meta.fromRow).hydrateAll(result);
  }

  /// Convenience for single-row inserts.
  Future<T> one(DbContext db) async {
    final rows = await run(db);
    if (rows.isEmpty) {
      throw InsertReturnedNoRowsException(
        'InsertQuery<$T> returned no rows (RETURNING disabled or '
        'ON CONFLICT swallowed the row)',
      );
    }
    return rows.first;
  }
}

/// `UPDATE` builder.
///
/// SET parameters and WHERE parameters share the same `$n` index space
/// via a single [SqlCompiler], which fixes the off-by-one bug in the
/// old `update.dart` where SET values and WHERE values were bound on
/// separate counters.
class UpdateQuery<T> {
  final TableMeta<T> _meta;
  final Map<String, Object?> _values;
  Expr<bool>? _where;
  bool _returning = true;

  UpdateQuery._(this._meta, this._values, Expr<bool>? where) : _where = where;

  UpdateQuery<T> where(Expr<bool> predicate) {
    _where = _where == null ? predicate : _where!.and(predicate);
    return this;
  }

  UpdateQuery<T> returning([bool enabled = true]) {
    _returning = enabled;
    return this;
  }

  CompiledSql compile() {
    if (_values.isEmpty) {
      throw InvalidQueryBuilderException(
        'UpdateQuery<$T> has no SET values',
      );
    }

    final c = SqlCompiler();
    final normalized = _normalizeKeys(_values);
    final setSql = normalized.entries
        .map((e) => '${e.key.safeTk} = ${c.bind(e.value)}')
        .join(', ');

    final buf = StringBuffer('UPDATE ${_meta.tableName.safeTk} SET $setSql');
    if (_where != null) {
      buf.write(' WHERE ${c.compile(_where!)}');
    }
    if (_returning) {
      buf.write(' RETURNING *');
    }
    return CompiledSql(buf.toString(), c.params);
  }

  /// Execute and return updated rows. Returns the affected row count
  /// when [returning] is disabled.
  Future<List<T>> run(DbContext db) async {
    final compiled = compile();
    final result = await db.execute(compiled.sql, parameters: compiled.params);
    if (!_returning) return const [];
    return Hydrator<T>(_meta.fromRow).hydrateAll(result);
  }
}

/// `DELETE` builder. Returns deleted rows when [returning] is on.
class DeleteQuery<T> {
  final TableMeta<T> _meta;
  Expr<bool>? _where;
  bool _returning = true;

  DeleteQuery._(this._meta, Expr<bool>? where) : _where = where;

  DeleteQuery<T> where(Expr<bool> predicate) {
    _where = _where == null ? predicate : _where!.and(predicate);
    return this;
  }

  DeleteQuery<T> returning([bool enabled = true]) {
    _returning = enabled;
    return this;
  }

  CompiledSql compile() {
    final c = SqlCompiler();
    final buf = StringBuffer('DELETE FROM ${_meta.tableName.safeTk}');
    if (_where != null) {
      buf.write(' WHERE ${c.compile(_where!)}');
    }
    if (_returning) {
      buf.write(' RETURNING *');
    }
    return CompiledSql(buf.toString(), c.params);
  }

  Future<List<T>> run(DbContext db) async {
    final compiled = compile();
    final result = await db.execute(compiled.sql, parameters: compiled.params);
    if (!_returning) return const [];
    return Hydrator<T>(_meta.fromRow).hydrateAll(result);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convert a camelCase identifier to snake_case.
/// e.g. `createdAt` → `created_at`, `emailOtp` → `email_otp`.
/// Already-snake_case keys are returned unchanged.
String _camelToSnake(String s) => s
    .replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}')
    .replaceFirst(RegExp(r'^_'), '');

/// Return a copy of [map] with every key normalised to snake_case so that
/// callers may pass camelCase keys (e.g. `{'createdAt': …}`) and still
/// produce valid SQL column references.
Map<String, Object?> _normalizeKeys(Map<String, Object?> map) {
  final out = <String, Object?>{};
  for (final entry in map.entries) {
    out[_camelToSnake(entry.key)] = entry.value;
  }
  return out;
}
