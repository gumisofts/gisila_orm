/// Test-only helpers for the gisila ORM.
///
/// Provides:
///
///  * [MockDbContext] - a [DbContext] that records every `(sql, params)`
///    call and replies with canned [Result]s. Use for unit tests where
///    a real database is overkill.
///  * [withTestDb] - integration helper that connects to the
///    docker-compose Postgres at `localhost:5454`, allocates a
///    randomly-named schema, runs [body] inside it, and drops the
///    schema afterwards. Skips gracefully (returns `null`) if the
///    database is not reachable.
library gisila.test.support.test_db;

import 'dart:io';
import 'dart:math';

import 'package:gisila_orm/gisila.dart';
import 'package:postgres/postgres.dart';

// ---------------------------------------------------------------------------
// MockDbContext
// ---------------------------------------------------------------------------

class _Call {
  final String sql;
  final List<Object?> params;
  const _Call(this.sql, this.params);
}

/// A [DbContext] that captures every call without touching a database.
class MockDbContext implements DbContext {
  final List<_Call> _calls = [];
  final Result Function(String sql, List<Object?> params)? _onExecute;

  /// Build a mock. [onExecute] returns a canned [Result] for each
  /// statement; if omitted, an empty [Result] is returned.
  MockDbContext({
    Result Function(String sql, List<Object?> params)? onExecute,
  }) : _onExecute = onExecute;

  /// All statements that were executed, in call order.
  List<String> get sqls => [for (final c in _calls) c.sql];

  /// Parameter lists in call order.
  List<List<Object?>> get params => [for (final c in _calls) c.params];

  /// How many times [execute] (or [stream]) was invoked.
  int get callCount => _calls.length;

  /// Reset the recording so a single [MockDbContext] instance can be
  /// reused across multiple assertions.
  void reset() => _calls.clear();

  @override
  Future<Result> execute(String sql,
      {List<Object?> parameters = const []}) async {
    _calls.add(_Call(sql, parameters));
    if (_onExecute != null) return _onExecute(sql, parameters);
    return _emptyResult();
  }

  @override
  Stream<ResultRow> stream(String sql,
      {List<Object?> parameters = const []}) async* {
    _calls.add(_Call(sql, parameters));
    final result =
        _onExecute != null ? _onExecute(sql, parameters) : _emptyResult();
    for (final row in result) {
      yield row;
    }
  }
}

/// Empty real [Result] (zero rows, empty schema). Backed by the actual
/// `package:postgres` types so every iterable / list method works as
/// expected without needing per-method stubbing.
Result _emptyResult() => Result(
      rows: const [],
      affectedRows: 0,
      schema: ResultSchema(const []),
    );

// ---------------------------------------------------------------------------
// withTestDb (integration)
// ---------------------------------------------------------------------------

/// Endpoint used for integration tests; aligned with `docker-compose.yml`.
const _testEndpoint = (
  host: 'localhost',
  port: 5454,
  database: 'postgres',
  username: 'postgres',
  password: 'postgres',
);

/// Run [body] inside a freshly allocated Postgres schema. The schema
/// is dropped (cascading) on completion. Returns `null` when the
/// docker Postgres is not reachable, so callers can skip gracefully.
///
/// We pin `maxConnections: 1` so the underlying pool reuses a single
/// physical connection. That makes session-level `SET search_path`
/// stick for every subsequent call - which would otherwise be lost
/// each time the pool handed out a different connection.
Future<R?> withTestDb<R>(
  Future<R> Function(Database db, String schema) body, {
  String username = 'postgres',
  String password = 'postgres',
  String database = 'postgres',
  int port = 5454,
}) async {
  if (!await isTestDbAvailable(port: port)) return null;

  final config = DatabaseConfig(connections: [
    DatabaseConnection(
      name: 'default',
      type: DatabaseType.postgresql,
      host: _testEndpoint.host,
      port: port,
      database: database,
      username: username,
      password: password,
      maxConnections: 1,
      additionalParams: const {'application_name': 'gisila-test'},
    ),
  ]);

  final schema = 'gisila_test_${_rand.nextInt(0x7fffffff).toRadixString(36)}';

  // Bootstrap connection: only used to CREATE SCHEMA before the real
  // pool sees it. We can't use `Database.onOpen` to do this because
  // the schema doesn't exist yet at the moment onOpen fires.
  final boot = await Connection.open(
    Endpoint(
      host: _testEndpoint.host,
      port: port,
      database: database,
      username: username,
      password: password,
    ),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );
  await boot.execute('CREATE SCHEMA "$schema"');
  await boot.close();

  Database? db;
  try {
    db = await Database.connect(
      config,
      onOpen: (connection) async {
        // Reapply on every physical connection - including the new
        // one the pool spawns after a transaction failure invalidates
        // the previous one.
        await connection.execute('SET search_path TO "$schema", public');
      },
    );
  } catch (_) {
    return null;
  }

  try {
    return await body(db, schema);
  } finally {
    try {
      final cleanup = await Connection.open(
        Endpoint(
          host: _testEndpoint.host,
          port: port,
          database: database,
          username: username,
          password: password,
        ),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );
      await cleanup.execute('DROP SCHEMA IF EXISTS "$schema" CASCADE');
      await cleanup.close();
    } catch (_) {/* best effort cleanup */}
    await db.close();
  }
}

/// Lightweight "is the test Postgres up?" probe that test files can
/// use to skip gracefully when running in environments without docker.
Future<bool> isTestDbAvailable({int port = 5454}) async {
  try {
    final s = await Socket.connect(_testEndpoint.host, port,
        timeout: const Duration(milliseconds: 250));
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

final _rand = Random.secure();
