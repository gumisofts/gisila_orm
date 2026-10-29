/// Glue between gisila_orm and the gisila web framework.
///
/// ```dart
/// import 'package:gisila/gisila.dart';
/// import 'package:gisila_orm/gisila.dart';
/// import 'package:gisila_orm/web.dart';
///
/// final db = await Database.connect(config);
/// final orm = GisilaOrmDatabaseProvider(db);
/// final app = GisilaApp(
///   config: AppConfig(
///     database: orm,                       // ctx.db<Database>()
///     dbErrorMapper: const PostgresDbErrorMapper(),
///     healthCheckPath: '/healthz',
///     healthCheck: orm.isHealthy,
///   ),
/// );
/// ```
library gisila_orm.web;

import 'package:gisila/gisila.dart'
    show
        BadRequest,
        Conflict,
        DatabaseProvider,
        DbErrorMapper,
        HttpException,
        Request;

import 'database/postgres/core/connections.dart';
import 'database/postgres/exceptions/exceptions.dart';

/// Hands every request the shared [Database]. Its pool lends a connection
/// per query, so nothing is opened or closed per request; `app.stop()`
/// closes the pool (unless [closeOnDispose] is false).
class GisilaOrmDatabaseProvider extends DatabaseProvider<Database> {
  GisilaOrmDatabaseProvider(this.database, {this.closeOnDispose = true});

  final Database database;

  /// Close [database] when the app stops. Turn off when something else
  /// owns it.
  final bool closeOnDispose;

  @override
  Future<Database> open(Request request) async => database;

  @override
  Future<void> close(Database session, {required bool ok}) async {}

  @override
  Future<void> dispose() async {
    if (closeOnDispose) await database.close();
  }

  /// `true` when a `SELECT 1` succeeds; pass it as `AppConfig.healthCheck`.
  Future<bool> isHealthy() async {
    try {
      await database.ping();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Turns Postgres errors from gisila_orm into client errors:
///
/// | Error | Status | Code |
/// | ----- | ------ | ---- |
/// | unique violation | 409 | `unique_violation` |
/// | exclusion violation | 409 | `exclusion_violation` |
/// | foreign key violation | 400 | `foreign_key_violation` |
/// | not-null violation | 400 | `not_null_violation` |
/// | check violation | 400 | `check_violation` |
/// | bad value (out of range, bad date, too long) | 400 | `invalid_value` |
/// | connection lost | 503 | `database_unavailable` |
///
/// Messages name the column (`"email" is already taken`) but never the
/// value: Postgres's own detail (`Key (email)=(ann@example.com) already
/// exists`) would tell anyone which emails are registered. The columns go
/// in `details.fields`. Anything else stays a 500.
class PostgresDbErrorMapper extends DbErrorMapper {
  const PostgresDbErrorMapper();

  @override
  HttpException? map(Object error, StackTrace stack) {
    if (error is! PostgresException) return null;
    final fields = _fields(error);
    final details = fields.isEmpty ? null : {'fields': fields};
    final named = fields.isEmpty ? null : fields.map((f) => '"$f"').join(', ');

    return switch (error) {
      PostgresUniqueViolationException() => Conflict(
          named == null
              ? 'A record with this value already exists.'
              : '$named ${fields.length == 1 ? 'is' : 'are'} already taken.',
          code: 'unique_violation',
          details: details),
      PostgresExclusionViolationException() => Conflict(
          'This conflicts with an existing record.',
          code: 'exclusion_violation',
          details: details),
      PostgresForeignKeyViolationException() => BadRequest(
          named == null
              ? 'A referenced record does not exist or is still in use.'
              : '$named must refer to an existing record.',
          code: 'foreign_key_violation',
          details: details),
      PostgresNotNullViolationException() => BadRequest(
          named == null
              ? 'A required value is missing.'
              : '$named is required.',
          code: 'not_null_violation',
          details: details),
      PostgresCheckViolationException() => BadRequest(
          'A value is not allowed.',
          code: 'check_violation',
          details: details),
      PostgresDataException() => BadRequest(
          'A value is invalid for its field.',
          code: 'invalid_value',
          details: details),
      PostgresConnectionException() => HttpException(
          503, 'The database is unavailable.',
          code: 'database_unavailable'),
      _ => null,
    };
  }

  static final _keyColumns = RegExp(r'^Key \(([^)]+)\)=');

  /// Column names from the error, never values.
  static List<String> _fields(PostgresException e) {
    final column = e.details?['column'];
    if (column is String && column.isNotEmpty) return [column];
    if (e is PostgresIntegrityConstraintViolationException &&
        e.columnName != null) {
      return [e.columnName!];
    }
    final detail = e.details?['detail'];
    if (detail is String) {
      final m = _keyColumns.firstMatch(detail);
      if (m != null) {
        return m
            .group(1)!
            .split(',')
            .map((c) => c.trim().replaceAll('"', ''))
            .where((c) => c.isNotEmpty)
            .toList();
      }
    }
    return const [];
  }
}
