/// Gisila configuration entry point.
///
/// Re-exports the [DatabaseConfig]/[DatabaseConnection] types so user
/// code can import a single library:
///
/// ```dart
/// import 'package:gisila_orm/config/config.dart';
///
/// final config = await DatabaseConfig.fromFile('database.yaml');
/// ```
library gisila.config;

export 'database_config.dart';
