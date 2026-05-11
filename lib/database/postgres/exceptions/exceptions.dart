export 'error_mapper.dart';
export 'postgresql_exceptions.dart';

class DefaultValueException implements Exception {
  String msg;
  DefaultValueException({required this.msg});
}

class QueryException implements Exception {
  String msg;
  QueryException({required this.msg});
}

class ValidationException implements Exception {
  List<String> errors;
  ValidationException({required this.errors});
}

/// Thrown when [DatabaseConfig] or [Database.connect] cannot resolve a
/// named connection.
class DatabaseConfigurationException implements Exception {
  DatabaseConfigurationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when [Query.one] matches no rows.
class QueryNoRowsException implements Exception {
  QueryNoRowsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when [Query.one] matches more than one row.
class QueryMultipleRowsException implements Exception {
  QueryMultipleRowsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when a query builder is used in an invalid state (for example
/// an [InsertQuery] with no rows or an [UpdateQuery] with no SET columns).
class InvalidQueryBuilderException implements Exception {
  InvalidQueryBuilderException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when [InsertQuery.one] yields no row (for example RETURNING
/// disabled or `ON CONFLICT DO NOTHING` skipping the insert).
class InsertReturnedNoRowsException implements Exception {
  InsertReturnedNoRowsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when eager loading cannot store a relation on a model that
/// does not mix in [Preloadable].
class PreloadException implements Exception {
  PreloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when [MigrationManager.down] cannot roll back (missing
/// migration file or empty down SQL).
class MigrationRollbackException implements Exception {
  MigrationRollbackException(this.message);
  final String message;
  @override
  String toString() => message;
}
