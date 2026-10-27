/// The [Database] runtime: manages named pools, hands out [DbContext]s,
/// and runs transactions. This is the only entry point that user code
/// should touch from `package:gisila_orm/gisila.dart` for connection
/// lifecycle.
library gisila.database.postgres.core.connections;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:gisila_orm/config/database_config.dart';
import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';
import 'package:gisila_orm/runtime/db_context.dart';
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
  Database._(this._config, this._pools, this._defaultName, this._onOpen,
      this._onQuery);

  /// Sees every statement run through this database (see [QueryObserver]).
  final QueryObserver? _onQuery;

  final DatabaseConfig _config;
  final Map<String, Pool<Connection>> _pools;

  /// What `prefer` resolved to per connection name, decided once in
  /// [connect] by asking each server whether it speaks TLS.
  final Map<String, SslMode> _preferredSsl = {};
  final Future<void> Function(Connection connection)? _onOpen;
  String _defaultName;

  /// Connect to all configured databases and return a [Database].
  /// Pools are created lazily on first use unless `eager: true`.
  ///
  /// Pass [onOpen] to run a setup callback on every new physical
  /// connection. This is the right place to apply session-level
  /// configuration like `SET search_path` that must survive a pool
  /// dropping a connection (e.g. after a transaction rolls back).
  ///
  /// Pass [onQuery] to observe every statement (SQL, parameters, duration,
  /// error), e.g. `onQuery: slowQueryLogger(Duration(milliseconds: 200),
  /// print)`.
  static Future<Database> connect(
    DatabaseConfig config, {
    String? defaultConnectionName,
    bool eager = false,
    Future<void> Function(Connection connection)? onOpen,
    QueryObserver? onQuery,
  }) async {
    final defaultName = defaultConnectionName ?? config.defaultConnection.name;
    if (!config.hasConnection(defaultName)) {
      throw DatabaseConfigurationException(
        'Connection "$defaultName" not found in config',
      );
    }

    final pools = <String, Pool<Connection>>{};
    final db = Database._(config, pools, defaultName, onOpen, onQuery);

    for (final name in config.connectionNames) {
      final c = config.getConnection(name)!;
      if (c.effectiveSslMode != DatabaseSslMode.prefer) continue;
      db._preferredSsl[name] =
          await _serverSupportsTls(c) ? SslMode.require : SslMode.disable;
    }

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
      sslMode: switch (connection.effectiveSslMode) {
        DatabaseSslMode.disable => SslMode.disable,
        DatabaseSslMode.prefer => _preferredSsl[name] ?? SslMode.require,
        DatabaseSslMode.require => SslMode.require,
        DatabaseSslMode.verifyFull => SslMode.verifyFull,
      },
      securityContext: _securityContextFor(connection),
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

  /// A TLS context trusting only [DatabaseConnection.sslRootCert], or null
  /// to use the system trust store.
  static SecurityContext? _securityContextFor(DatabaseConnection c) {
    final caFile = c.sslRootCert;
    if (caFile == null) return null;
    try {
      return SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(caFile);
    } on Object catch (e) {
      throw DatabaseConfigurationException(
          'Cannot load sslrootcert "$caFile" for connection "${c.name}": $e');
    }
  }

  /// Sends Postgres's SSLRequest and reads the one-byte answer: `S` means
  /// the server will speak TLS, `N` means it won't. This is how libpq's
  /// `sslmode=prefer` decides. Assumes TLS when the server can't be
  /// reached, so the real connection attempt reports the error.
  static Future<bool> _serverSupportsTls(DatabaseConnection c) async {
    Socket? socket;
    try {
      socket = await Socket.connect(c.host, c.port,
          timeout: Duration(seconds: c.connectionTimeout));
      // Length 8, then the SSLRequest code 80877103 (1234 << 16 | 5679).
      final request = ByteData(8)
        ..setInt32(0, 8)
        ..setInt32(4, 80877103);
      socket.add(request.buffer.asUint8List());
      await socket.flush();
      final reply =
          await socket.first.timeout(Duration(seconds: c.connectionTimeout));
      return reply.isNotEmpty && reply.first == 0x53; // 'S'
    } on Object {
      return true;
    } finally {
      socket?.destroy();
    }
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
      PoolDbContext(_poolFor(connectionName ?? _defaultName),
          observer: _onQuery);

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
  ///
  /// Called inside another transaction on the same connection name, it
  /// runs [body] in a savepoint of that transaction ([settings] then do
  /// not apply): a throw rolls back only [body]'s work.
  Future<R> transaction<R>(
    Future<R> Function(TxDbContext tx) body, {
    String? connectionName,
    TransactionSettings? settings,
  }) async {
    final pool = _poolFor(connectionName ?? _defaultName);
    return runTransaction(pool, pool.runTx, body,
        settings: settings, observer: _onQuery);
  }

  /// Run [body] on one connection borrowed from the pool for its whole
  /// duration, so session state (advisory locks, session `SET`s) carries
  /// across statements. Undo any session state before returning: the
  /// connection goes back to the pool afterwards.
  Future<R> withConnection<R>(
    Future<R> Function(ConnectionDbContext connection) body, {
    String? connectionName,
  }) {
    final pool = _poolFor(connectionName ?? _defaultName);
    return pool.withConnection(
        (conn) => body(ConnectionDbContext(conn, observer: _onQuery)));
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
