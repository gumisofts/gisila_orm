/// The [Database] runtime: manages named pools, hands out [DbContext]s,
/// and runs transactions. This is the only entry point that user code
/// should touch from `package:gisila/gisila.dart` for connection
/// lifecycle.
library gisila.database.postgres.core.connections;

import 'dart:async';

import 'package:gisila/config/database_config.dart';
import 'package:gisila/database/postgres/exceptions/exceptions.dart';
import 'package:gisila/runtime/db_context.dart';
import 'package:postgres/postgres.dart';

/// A connected gisila database. Holds one or more named connection
/// pools backed by `package:postgres`.
///
/// Typical usage:
///
/// ```dart
/// final config = await DatabaseConfig.fromFile('database.yaml');
/// final db = await Database.connect(config);
///
/// await db.execute('SELECT 1');
///
/// await db.transaction((tx) async {
///   await tx.execute('INSERT INTO users (name) VALUES ($1)', parameters: ['x']);
/// });
///
/// await db.close();
/// ```
class Database {
  Database._(this._config, this._pools, this._defaultName, this._onOpen);

  final DatabaseConfig _config;
  final Map<String, Pool<Connection>> _pools;
  final Future<void> Function(Connection connection)? _onOpen;
  String _defaultName;

  /// Connect to all configured databases and return a [Database].
  /// Pools are created lazily on first use unless `eager: true`.
  ///
  /// Pass [onOpen] to run a setup callback on every new physical
  /// connection. This is the right place to apply session-level
  /// configuration like `SET search_path` that must survive a pool
  /// dropping a connection (e.g. after a transaction rolls back).
  static Future<Database> connect(
    DatabaseConfig config, {
    String? defaultConnectionName,
    bool eager = false,
    Future<void> Function(Connection connection)? onOpen,
  }) async {
    final defaultName = defaultConnectionName ?? config.defaultConnection.name;
    if (!config.hasConnection(defaultName)) {
      throw DatabaseConfigurationException(
        'Connection "$defaultName" not found in config',
      );
    }

    final pools = <String, Pool<Connection>>{};
    final db = Database._(config, pools, defaultName, onOpen);

    if (eager) {
      for (final name in config.connectionNames) {
        db._poolFor(name);
      }
    } else {
      // Force-create the default pool so misconfiguration surfaces now.
      db._poolFor(defaultName);
    }

    return db;
  }

  /// Lazy pool creation. Builds a `Pool<Connection>` from the named
  /// [DatabaseConnection], translating gisila settings into
  /// `package:postgres` settings (including `maxConnectionCount`).
  Pool<Connection> _poolFor(String name) {
    final cached = _pools[name];
    if (cached != null) return cached;

    final connection = _config.getConnection(name);
    if (connection == null) {
      throw DatabaseConfigurationException(
        'Connection "$name" not found in configuration',
      );
    }
    if (connection.type != DatabaseType.postgresql) {
      throw UnsupportedError(
        'Only PostgreSQL connections are currently supported',
      );
    }

    final endpoint = Endpoint(
      host: connection.host,
      port: connection.port,
      database: connection.database,
      username: connection.username,
      password: connection.password,
    );

    final settings = PoolSettings(
      maxConnectionCount: connection.maxConnections,
      sslMode: connection.useSSL ? SslMode.require : SslMode.disable,
      connectTimeout: Duration(seconds: connection.connectionTimeout),
      queryTimeout: Duration(seconds: connection.queryTimeout),
      applicationName:
          connection.additionalParams['application_name'] as String?,
      onOpen: _onOpen,
    );

    final pool = Pool<Connection>.withEndpoints([endpoint], settings: settings);
    _pools[name] = pool;
    return pool;
  }

  /// Switch the default named connection used by [execute] and
  /// [transaction] when no `connectionName` is specified.
  void useConnection(String name) {
    if (!_config.hasConnection(name)) {
      throw ArgumentError('Connection "$name" does not exist');
    }
    _defaultName = name;
  }

  /// The name of the default connection.
  String get defaultConnectionName => _defaultName;

  /// Names of all configured connections.
  List<String> get connectionNames => _config.connectionNames;

  /// A [DbContext] for the default (or named) pool. Use this to run
  /// statements outside a transaction; each call acquires a connection
  /// from the pool independently.
  DbContext context([String? connectionName]) =>
      PoolDbContext(_poolFor(connectionName ?? _defaultName));

  /// One-shot statement execution. Acquires a connection from the
  /// default pool, runs the statement, returns the result. For
  /// repeated statements that should share a connection, prefer
  /// [transaction].
  Future<Result> execute(
    String sql, {
    List<Object?> parameters = const [],
    String? connectionName,
  }) =>
      context(connectionName).execute(sql, parameters: parameters);

  /// Run [body] inside a database transaction. The same [TxDbContext]
  /// is passed to [body] and is the only connection that should be
  /// used inside the closure. If [body] throws, the transaction is
  /// rolled back; otherwise it is committed.
  Future<R> transaction<R>(
    Future<R> Function(TxDbContext tx) body, {
    String? connectionName,
    TransactionSettings? settings,
  }) async {
    final pool = _poolFor(connectionName ?? _defaultName);
    try {
      return await pool.runTx<R>(
        (session) => body(TxDbContext(session)),
        settings: settings,
      );
    } on ServerException catch (e) {
      throw PostgresErrorMapper.fromServerException(e);
    }
  }

  /// Cheap liveness check (`SELECT 1`).
  Future<void> ping([String? connectionName]) async {
    await execute('SELECT 1', connectionName: connectionName);
  }

  /// Close all pools and release resources.
  Future<void> close() async {
    for (final pool in _pools.values) {
      await pool.close();
    }
    _pools.clear();
  }
}
