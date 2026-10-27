/// The unified execution context that all queries run on.
///
/// `Query<T>` and friends never touch a raw `Pool` or `TxSession`
/// directly. Instead they go through a [DbContext], which is either:
///
///   * [PoolDbContext] - acquires a connection from the pool on each
///     call (used for one-shot statements outside a transaction), or
///   * [TxDbContext] - wraps a single `TxSession` for the duration of
///     a transaction so every statement inside `db.transaction(...)`
///     runs against the same session, or
///   * [ConnectionDbContext] - one connection borrowed from the pool by
///     `db.withConnection(...)`, for session state such as advisory locks.
///
/// Both implementations route every error through
/// [PostgresErrorMapper] so callers always see `PostgresException`s
/// from `lib/database/postgres/exceptions/postgresql_exceptions.dart`.
library gisila.runtime.db_context;

import 'dart:async';

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
  ///
  /// A `SELECT`, `VALUES` or `TABLE` query is read through a server-side
  /// cursor, [cursorBatchSize] rows at a time, in a transaction that holds
  /// one connection until the stream is done or cancelled. Pausing the
  /// subscription stops fetching. Other statements are buffered.
  Stream<ResultRow> stream(
    String sql, {
    List<Object?> parameters = const [],
  });
}

/// Rows fetched per round trip by [DbContext.stream].
const cursorBatchSize = 500;

final _cursorable =
    RegExp(r'^\s*(select|values|table)\b', caseSensitive: false);

/// Runs [sql] through a cursor inside the transaction that [runTx] opens,
/// as a stream that pauses and cancels the fetching with its listener.
Stream<ResultRow> _streamInTransaction(
  Future<void> Function(Future<void> Function(TxDbContext tx) body) runTx,
  String sql,
  List<Object?> parameters,
) {
  late final StreamController<ResultRow> out;
  out = StreamController<ResultRow>(onListen: () async {
    var forwarded = false;
    final noteErrors = StreamTransformer<ResultRow, ResultRow>.fromHandlers(
      handleError: (e, st, sink) {
        forwarded = true;
        sink.addError(e, st);
      },
    );

    try {
      await runTx((tx) => out.addStream(
          tx.stream(sql, parameters: parameters).transform(noteErrors),
          cancelOnError: true));
    } catch (e, st) {
      // The driver rethrows a statement's error when the transaction ends;
      // the listener has seen it already.
      if (!forwarded) out.addError(e, st);
    } finally {
      await out.close();
    }
  });
  return out.stream;
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
  }) {
    if (!_cursorable.hasMatch(sql)) {
      return _buffered(execute(sql, parameters: parameters));
    }
    return _streamInTransaction(
      (body) => runTransaction(_pool, _pool.runTx, body),
      sql,
      parameters,
    );
  }
}

Stream<ResultRow> _buffered(Future<Result> result) async* {
  for (final row in await result) {
    yield row;
  }
}

/// A [DbContext] that runs every statement against a single
/// `TxSession`. Used inside `Database.transaction(...)` callbacks.
class TxDbContext implements DbContext {
  TxDbContext(this._session);

  final TxSession _session;
  int _savepoints = 0;
  int _cursors = 0;

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
    if (!_cursorable.hasMatch(sql)) {
      yield* _buffered(execute(sql, parameters: parameters));
      return;
    }
    final cursor = '"gisila_cursor_${++_cursors}"';
    final query = sql.trim().replaceFirst(RegExp(r';+$'), '');
    await execute('DECLARE $cursor NO SCROLL CURSOR FOR $query',
        parameters: parameters);
    var done = false;
    try {
      while (true) {
        final batch = await execute('FETCH $cursorBatchSize FROM $cursor');
        for (final row in batch) {
          yield row;
        }
        if (batch.length < cursorBatchSize) break;
      }
      done = true;
      await execute('CLOSE $cursor');
    } finally {
      // Cancelled early: free the cursor so the transaction can go on. After
      // a failed FETCH the transaction is aborted and CLOSE would fail too.
      if (!done) {
        try {
          await execute('CLOSE $cursor');
        } on Object catch (_) {}
      }
    }
  }

  /// Run [body] inside a savepoint of this transaction. If [body] throws,
  /// everything it did is rolled back and the error is rethrown; the outer
  /// transaction stays usable. Otherwise the savepoint is released and its
  /// work commits with the outer transaction.
  ///
  /// `db.transaction(...)` called inside another transaction on the same
  /// database does this for you.
  Future<R> savepoint<R>(Future<R> Function(TxDbContext tx) body) async {
    final name = '"gisila_sp_${++_savepoints}"';
    await execute('SAVEPOINT $name');
    final R result;
    try {
      result = await body(this);
    } catch (_) {
      await execute('ROLLBACK TO SAVEPOINT $name');
      await execute('RELEASE SAVEPOINT $name');
      rethrow;
    }
    await execute('RELEASE SAVEPOINT $name');
    return result;
  }

  /// Roll back the in-flight transaction explicitly.
  Future<void> rollback() => _session.rollback();
}

final _activeTxKey = Object();

class _ActiveTx {
  _ActiveTx(this.owner, this.tx);
  final Object owner;
  final TxDbContext tx;
  bool open = true;
}

/// Runs [body] in a transaction opened by [runTx] on [owner] (a pool or a
/// connection). Called again from inside that body, for the same [owner],
/// it uses a savepoint of the running transaction instead: a second
/// transaction would need a second connection and would not be atomic
/// with the first.
Future<R> runTransaction<R>(
  Object owner,
  Future<R> Function(Future<R> Function(TxSession session) fn,
          {TransactionSettings? settings})
      runTx,
  Future<R> Function(TxDbContext tx) body, {
  TransactionSettings? settings,
}) async {
  final outer = Zone.current[_activeTxKey];
  if (outer is _ActiveTx && outer.open && identical(outer.owner, owner)) {
    return outer.tx.savepoint(body);
  }
  try {
    return await runTx((session) {
      final active = _ActiveTx(owner, TxDbContext(session));
      return runZoned(
        () => body(active.tx).whenComplete(() => active.open = false),
        zoneValues: {_activeTxKey: active},
      );
    }, settings: settings);
  } on ServerException catch (e) {
    throw PostgresErrorMapper.fromServerException(e);
  }
}

/// A [DbContext] pinned to one pooled connection for the duration of
/// `Database.withConnection(...)`. Session-level state (advisory locks,
/// `SET` without `LOCAL`) persists across calls, and [transaction] runs
/// on the same connection.
class ConnectionDbContext implements DbContext {
  ConnectionDbContext(this._connection);

  final Connection _connection;

  @override
  Future<Result> execute(
    String sql, {
    List<Object?> parameters = const [],
  }) async {
    try {
      return await _connection.execute(
        sql,
        parameters: parameters.isEmpty ? null : parameters,
        queryMode: QueryMode.extended,
      );
    } on ServerException catch (e) {
      throw PostgresErrorMapper.fromServerException(e, query: sql);
    }
  }

  /// Cursor-backed queries run in a transaction on this connection, so
  /// other statements on it wait until the stream is done.
  @override
  Stream<ResultRow> stream(
    String sql, {
    List<Object?> parameters = const [],
  }) {
    if (!_cursorable.hasMatch(sql)) {
      return _buffered(execute(sql, parameters: parameters));
    }
    return _streamInTransaction(transaction, sql, parameters);
  }

  /// Run [body] in a transaction on this connection, or in a savepoint
  /// when called from inside one.
  Future<R> transaction<R>(Future<R> Function(TxDbContext tx) body) =>
      runTransaction(_connection, _connection.runTx, body);
}
