/// Database configuration handler for Gisila ORM.
///
/// Loads PostgreSQL connection settings from YAML files, environment
/// variables, or programmatically. Pool lifecycle is owned by
/// [Database] in `lib/database/postgres/core/connections.dart`; this
/// file only exposes the configuration values that drive it.
library gisila.config;

import 'dart:io';

import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';
import 'package:yaml/yaml.dart';

/// Supported database types. Phase 1 of gisila ships PostgreSQL only;
/// the enum is preserved for forward-compatibility with later backends.
enum DatabaseType {
  postgresql,
}

/// How a connection uses TLS, following libpq's `sslmode` values.
enum DatabaseSslMode {
  /// Plain TCP. Passwords may travel in clear text.
  disable,

  /// TLS when the server supports it, plain TCP otherwise (libpq `allow`
  /// and `prefer`). Like libpq, certificates aren't verified, and an
  /// active attacker can force plain TCP.
  prefer,

  /// Always TLS, without verifying the server certificate.
  require,

  /// Always TLS, verifying the certificate chain and the host name
  /// (libpq `verify-full`; `verify-ca` maps here too, since the driver
  /// can't skip the host name check).
  verifyFull;

  /// Parses a libpq `sslmode` value (case-insensitive). Throws
  /// [ArgumentError] for anything else rather than guessing.
  static DatabaseSslMode parse(String value) {
    switch (value.trim().toLowerCase()) {
      case 'disable':
        return DatabaseSslMode.disable;
      case 'allow':
      case 'prefer':
        return DatabaseSslMode.prefer;
      case 'require':
        return DatabaseSslMode.require;
      case 'verify-ca':
      case 'verify-full':
      case 'verify_full':
      case 'verifyfull':
        return DatabaseSslMode.verifyFull;
    }
    throw ArgumentError.value(value, 'sslmode',
        'expected disable, allow, prefer, require, verify-ca or verify-full');
  }
}

/// Configuration for a single named database connection.
class DatabaseConnection {
  /// Connection identifier (used as the lookup name in [DatabaseConfig]).
  final String name;

  /// Database backend type.
  final DatabaseType type;

  /// Database server host.
  final String host;

  /// Database server port.
  final int port;

  /// Database name on the server.
  final String database;

  /// Username for authentication.
  final String username;

  /// Password for authentication.
  final String password;

  /// Whether to require SSL. Kept for older configs; [sslMode] wins when
  /// set. True whenever [effectiveSslMode] isn't `disable`.
  final bool useSSL;

  /// How to use TLS. Null means [useSSL] decides (`require` or `disable`).
  final DatabaseSslMode? sslMode;

  /// PEM file of CA certificates to trust instead of the system store,
  /// for [DatabaseSslMode.verifyFull] (libpq `sslrootcert`).
  final String? sslRootCert;

  /// The TLS mode actually used.
  DatabaseSslMode get effectiveSslMode =>
      sslMode ?? (useSSL ? DatabaseSslMode.require : DatabaseSslMode.disable);

  /// Connection establishment timeout in seconds.
  final int connectionTimeout;

  /// Per-query timeout in seconds.
  final int queryTimeout;

  /// Upper bound on simultaneous physical connections in the pool.
  final int maxConnections;

  /// Lower bound on connections kept warm in the pool.
  final int minConnections;

  /// Backend-specific extra parameters (e.g. `application_name`,
  /// `search_path`). Forwarded into pool settings where applicable.
  final Map<String, dynamic> additionalParams;

  const DatabaseConnection({
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    this.useSSL = false,
    this.sslMode,
    this.sslRootCert,
    this.connectionTimeout = 30,
    this.queryTimeout = 30,
    this.maxConnections = 10,
    this.minConnections = 2,
    this.additionalParams = const {},
  });

  /// Convenience factory for PostgreSQL.
  factory DatabaseConnection.postgresql({
    required String name,
    required String host,
    required String database,
    required String username,
    required String password,
    int port = 5432,
    bool useSSL = false,
    DatabaseSslMode? sslMode,
    String? sslRootCert,
    int connectionTimeout = 30,
    int queryTimeout = 30,
    int maxConnections = 10,
    int minConnections = 2,
    Map<String, dynamic> additionalParams = const {},
  }) =>
      DatabaseConnection(
        name: name,
        type: DatabaseType.postgresql,
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
        useSSL: useSSL,
        sslMode: sslMode,
        sslRootCert: sslRootCert,
        connectionTimeout: connectionTimeout,
        queryTimeout: queryTimeout,
        maxConnections: maxConnections,
        minConnections: minConnections,
        additionalParams: additionalParams,
      );

  /// Parse a YAML/JSON-style map into a [DatabaseConnection].
  factory DatabaseConnection.fromMap(String name, Map<String, dynamic> config) {
    final typeStr = (config['type'] as String?) ?? 'postgresql';
    final type = DatabaseType.values.firstWhere(
      (e) => e.name == typeStr,
      orElse: () => throw ArgumentError('Unsupported database type: $typeStr'),
    );

    return DatabaseConnection(
      name: name,
      type: type,
      host: (config['host'] as String?) ?? 'localhost',
      port: (config['port'] as int?) ?? 5432,
      database: config['database'] as String,
      username: (config['username'] as String?) ?? 'postgres',
      password: (config['password'] as String?) ?? '',
      useSSL: (config['ssl'] as bool?) ?? false,
      sslMode: config['ssl_mode'] == null
          ? null
          : DatabaseSslMode.parse(config['ssl_mode'].toString()),
      sslRootCert: config['ssl_root_cert'] as String?,
      connectionTimeout: (config['connection_timeout'] as int?) ?? 30,
      queryTimeout: (config['query_timeout'] as int?) ?? 30,
      maxConnections: (config['max_connections'] as int?) ?? 10,
      minConnections: (config['min_connections'] as int?) ?? 2,
      additionalParams:
          (config['additional_params'] as Map?)?.cast<String, dynamic>() ??
              const {},
    );
  }

  /// Serialize the connection back to a map (for round-tripping configs).
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'type': type.name,
      'host': host,
      'port': port,
      'database': database,
      'username': username,
      'password': password,
      'connection_timeout': connectionTimeout,
      'query_timeout': queryTimeout,
      'max_connections': maxConnections,
      'min_connections': minConnections,
    };

    if (useSSL) map['ssl'] = useSSL;
    if (sslMode != null) map['ssl_mode'] = _sslModeName(sslMode!);
    if (sslRootCert != null) map['ssl_root_cert'] = sslRootCert;
    if (additionalParams.isNotEmpty) {
      map['additional_params'] = additionalParams;
    }

    return map;
  }

  /// Standard connection-string form (handy for libpq tools). Contains
  /// the password, so don't log it.
  String get connectionString {
    final query = <String, String>{
      if (effectiveSslMode != DatabaseSslMode.disable)
        'sslmode': _sslModeName(effectiveSslMode),
      if (sslRootCert != null) 'sslrootcert': sslRootCert!,
    };
    return Uri(
      scheme: 'postgresql',
      userInfo: '${Uri.encodeComponent(username)}:'
          '${Uri.encodeComponent(password)}',
      host: host,
      port: port,
      path: '/${Uri.encodeComponent(database)}',
      queryParameters: query.isEmpty ? null : query,
    ).toString();
  }

  static String _sslModeName(DatabaseSslMode mode) => switch (mode) {
        DatabaseSslMode.disable => 'disable',
        DatabaseSslMode.prefer => 'prefer',
        DatabaseSslMode.require => 'require',
        DatabaseSslMode.verifyFull => 'verify-full',
      };

  /// Parses a `postgres://` / `postgresql://` URL such as `DATABASE_URL`.
  ///
  /// Credentials and the database name are percent-decoded, and the
  /// password is everything after the first `:`, so it may contain `:`,
  /// `@` (encoded) and so on. `sslmode` takes every libpq value (see
  /// [DatabaseSslMode.parse]); `ssl=true` means `require`; `sslrootcert`
  /// names a CA file. `user`/`password` query parameters override the
  /// user info, as in libpq.
  factory DatabaseConnection.fromUrl(String name, String url) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'postgresql' && uri.scheme != 'postgres') {
      throw ArgumentError('Unsupported database scheme: ${uri.scheme}');
    }
    final query = uri.queryParameters;

    String? user;
    String? password;
    if (uri.userInfo.isNotEmpty) {
      final colon = uri.userInfo.indexOf(':');
      user = Uri.decodeComponent(
          colon < 0 ? uri.userInfo : uri.userInfo.substring(0, colon));
      if (colon >= 0) {
        password = Uri.decodeComponent(uri.userInfo.substring(colon + 1));
      }
    }
    user = query['user'] ?? user;
    password = query['password'] ?? password;

    DatabaseSslMode? sslMode;
    if (query['sslmode'] != null) {
      sslMode = DatabaseSslMode.parse(query['sslmode']!);
    } else if (const {'true', '1', 'yes', 'require'}
        .contains(query['ssl']?.toLowerCase())) {
      sslMode = DatabaseSslMode.require;
    }
    final rootCert = query['sslrootcert'];

    return DatabaseConnection(
      name: name,
      type: DatabaseType.postgresql,
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      // pathSegments are already percent-decoded.
      database: uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '',
      username: (user == null || user.isEmpty) ? 'postgres' : user,
      password: password ?? '',
      useSSL: sslMode != null && sslMode != DatabaseSslMode.disable,
      sslMode: sslMode,
      // libpq's `system` means "the default trust store".
      sslRootCert: rootCert == 'system' ? null : rootCert,
    );
  }

  @override
  String toString() =>
      'DatabaseConnection(name: $name, type: ${type.name}, database: $database)';
}

/// Aggregate of named [DatabaseConnection]s, with one designated default.
class DatabaseConfig {
  final Map<String, DatabaseConnection> _connections = {};
  String _defaultConnection;

  DatabaseConfig({
    List<DatabaseConnection> connections = const [],
    String defaultConnection = 'default',
  }) : _defaultConnection = defaultConnection {
    for (final connection in connections) {
      _connections[connection.name] = connection;
    }
  }

  /// Load configuration from a YAML file.
  static Future<DatabaseConfig> fromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Database config file not found: $filePath');
    }
    final yaml = loadYaml(await file.readAsString());
    return DatabaseConfig.fromMap(_yamlToMap(yaml) as Map<String, dynamic>);
  }

  /// Build a configuration from a parsed map.
  static DatabaseConfig fromMap(Map<String, dynamic> config) {
    final connections = <DatabaseConnection>[];
    final connectionsMap =
        (config['connections'] as Map?)?.cast<String, dynamic>() ?? const {};

    for (final entry in connectionsMap.entries) {
      connections.add(
        DatabaseConnection.fromMap(
          entry.key,
          (entry.value as Map).cast<String, dynamic>(),
        ),
      );
    }

    return DatabaseConfig(
      connections: connections,
      defaultConnection: (config['default'] as String?) ?? 'default',
    );
  }

  /// Load configuration with environment-variable overrides.
  ///
  /// Precedence (highest first):
  /// 1. `DATABASE_URL` — replaces/sets the default connection
  /// 2. `DB_CONNECTIONS` + `DB_<NAME>_URL` — named connections
  /// 3. Optional [configFile] YAML (default `database.yaml`) when the file exists
  ///
  /// File-less deploys (e.g. Gisila Panel) should set `DATABASE_URL` and may omit
  /// the YAML entirely.
  static Future<DatabaseConfig> fromEnvironment({
    String configFile = 'database.yaml',
    Map<String, String>? envOverrides,
  }) async {
    final env = envOverrides ?? Platform.environment;

    DatabaseConfig config;
    final file = File(configFile);
    if (await file.exists()) {
      config = await DatabaseConfig.fromFile(configFile);
    } else {
      config = DatabaseConfig();
    }

    final defaultUrl = env['DATABASE_URL'];
    if (defaultUrl != null) {
      config._connections['default'] =
          _parseConnectionString('default', defaultUrl);
      config._defaultConnection = 'default';
    }

    final names = env['DB_CONNECTIONS']?.split(',') ?? const <String>[];
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      final url = env['DB_${name.toUpperCase()}_URL'];
      if (url != null) {
        config._connections[name] = _parseConnectionString(name, url);
      }
    }

    return config;
  }

  static DatabaseConnection _parseConnectionString(
    String name,
    String connectionString,
  ) =>
      DatabaseConnection.fromUrl(name, connectionString);

  /// Recursively convert a YamlMap/YamlList tree into plain Dart maps/lists.
  static dynamic _yamlToMap(dynamic yaml) {
    if (yaml is YamlMap) {
      return {
        for (final entry in yaml.entries)
          entry.key.toString(): _yamlToMap(entry.value),
      };
    }
    if (yaml is YamlList) {
      return yaml.map(_yamlToMap).toList();
    }
    return yaml;
  }

  /// Register or replace a named connection.
  void addConnection(DatabaseConnection connection) {
    _connections[connection.name] = connection;
  }

  /// Remove a named connection. The current default cannot be removed.
  void removeConnection(String name) {
    if (name == _defaultConnection) {
      throw ArgumentError('Cannot remove the default connection');
    }
    _connections.remove(name);
  }

  /// Look up a connection by name (defaults to the default connection).
  DatabaseConnection? getConnection([String? name]) =>
      _connections[name ?? _defaultConnection];

  /// Get the default connection or throw if it has not been registered.
  DatabaseConnection get defaultConnection {
    final connection = _connections[_defaultConnection];
    if (connection == null) {
      throw DatabaseConfigurationException(
        'Default connection "$_defaultConnection" not found',
      );
    }
    return connection;
  }

  /// Switch the default connection name.
  void setDefaultConnection(String name) {
    if (!_connections.containsKey(name)) {
      throw ArgumentError('Connection "$name" does not exist');
    }
    _defaultConnection = name;
  }

  /// Names of all registered connections.
  List<String> get connectionNames => _connections.keys.toList();

  /// Whether a connection with the given name exists.
  bool hasConnection(String name) => _connections.containsKey(name);

  /// Read-only view of all connections.
  Map<String, DatabaseConnection> get connections =>
      Map.unmodifiable(_connections);

  /// Serialize the whole configuration to a map.
  Map<String, dynamic> toMap() => {
        'default': _defaultConnection,
        'connections': {
          for (final entry in _connections.entries)
            entry.key: entry.value.toMap(),
        },
      };
}
