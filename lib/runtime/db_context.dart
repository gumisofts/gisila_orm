/// The unified execution context that all queries run on.
///
/// `Query<T>` and friends never touch a raw `Pool` or `TxSession`
/// directly. Instead they go through a [DbContext], which is either:
///
///   * [PoolDbContext] - acquires a connection from the pool on each
///     call (used for one-shot statements outside a transaction), or
///   * [TxDbContext] - wraps a single `TxSession` for the duration of
///     a transaction so every statement inside `db.transaction(...)`
///     runs against the same session.
///
/// Both implementations route every error through
/// [PostgresErrorMapper] so callers always see `PostgresException`s
/// from `lib/database/postgres/exceptions/postgresql_exceptions.dart`.
library gisila.runtime.db_context;

import 'package:gisila_orm/database/postgres/exceptions/error_mapper.dart';
import 'package:postgres/postgres.dart';

/// Thin abstraction over a Postgres `Session` (a pool, a connection
/// borrowed from the pool, or an in-flight transaction).
abstract class DbContext {
  /// Execute [sql] with positional [parameters]. Parameters use
  /// `$1, $2, ...` placeholders matching their position in the list.
  ///
  /// `ServerException`s thrown by the driver are translated into
  /// the typed `PostgresException` hierarchy before being rethrown.
  Future<Result> execute(String sql, {List<Object?> parameters = const []});

  /// Stream rows of [sql] without buffering the entire result set.
  /// Useful for very large queries.
  Stream<ResultRow> stream(
    String sql, {
    List<Object?> parameters = const [],
  });
}

/// A [DbContext] backed by the connection pool. Each call acquires a
/// connection from the pool, runs the statement, and returns the
/// connection to the pool when done.
class PoolDbContext implements DbContext {
  PoolDbContext(this._pool);

  final Pool<Connection> _pool;

  @override
  Future<Result> execute(
    String sql, {
    List<Object?> parameters = const [],
  }) async {
    try {
      // Pass the raw SQL string with native `$1, $2, ...` placeholders.
      // The driver uses the Postgres wire protocol's prepared-statement
      // mode for parameter binding when [parameters] is non-empty -
      // wrapping in `Sql.indexed` would route through the Dart-side
      // tokenizer which does not understand bare `$n` tokens.
      return await _pool.execute(
        sql,
        parameters: parameters.isEmpty ? null : parameters,
        queryMode: QueryMode.extended,
      );
    } on ServerException catch (e) {
      throw PostgresErrorMapper.fromServerException(e, query: sql);
    }
  }

  @override
  Stream<ResultRow> stream(
    String sql, {
    List<Object?> parameters = const [],
  }) async* {
    // A real streaming implementation would borrow a single connection
    // and stream rows from a prepared statement. For now we rely on
    // execute and yield each row, which is enough for the v1 ORM.
    final result = await execute(sql, parameters: parameters);
    for (final row in result) {
      yield row;
    }
  }
}

/// A [DbContext] that runs every statement against a single
/// `TxSession`. Used inside `Database.transaction(...)` callbacks.
class TxDbContext implements DbContext {
  TxDbContext(this._session);

  final TxSession _session;

  @override
  Future<Result> execute(
    String sql, {
    List<Object?> parameters = const [],
  }) async {
    try {
      return await _session.execute(
        sql,
        parameters: parameters.isEmpty ? null : parameters,
        queryMode: QueryMode.extended,
      );
    } on ServerException catch (e) {
      throw PostgresErrorMapper.fromServerException(e, query: sql);
    }
  }

  @override
  Stream<ResultRow> stream(
    String sql, {
    List<Object?> parameters = const [],
  }) async* {
    final result = await execute(sql, parameters: parameters);
    for (final row in result) {
      yield row;
    }
  }

  /// Roll back the in-flight transaction explicitly.
  Future<void> rollback() => _session.rollback();
}
