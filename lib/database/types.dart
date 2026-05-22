/// Default-value formatting helpers used by the schema code generator.
///
/// `DefaultEngine.formatForSql` validates a YAML default value against the
/// declared Dart type and returns the literal SQL fragment that should be
/// emitted into a `DEFAULT ...` clause.
library gisila.database.types;

import 'package:gisila_orm/database/extensions.dart';
import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';

/// Validates and formats column default values.
///
/// The class previously carried a hard-to-spot bug for boolean defaults
/// where the literal `'false'` was rejected. The new implementation
/// rejects only values outside the allowed set for the target type.
class DefaultEngine {
  const DefaultEngine();

  /// Static convenience instance.
  static const DefaultEngine instance = DefaultEngine();

  /// Format a YAML-supplied default `value` for a column whose Dart
  /// type name is [dartType] (e.g. `'int'`, `'String'`, `'bool'`).
  ///
  /// Returns a SQL literal suitable to drop into `DEFAULT <literal>`.
  /// Throws [DefaultValueException] for invalid combinations.
  String formatForSql(dynamic value, String dartType) {
    if (value == null) return 'NULL';

    switch (dartType) {
      case 'bool':
        final str = value.toString();
        if (str != 'true' && str != 'false') {
          throw DefaultValueException(
            msg: 'Invalid default value for bool: "$str"',
          );
        }
        return str.toUpperCase();

      case 'int':
        if (value is int) return value.toString();
        final str = value.toString();
        if (!RegExp(r'^-?\d+$').hasMatch(str)) {
          throw DefaultValueException(
            msg: 'Invalid default value for int: "$str"',
          );
        }
        return str;

      case 'double':
        if (value is num) return value.toString();
        final str = value.toString();
        if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(str)) {
          throw DefaultValueException(
            msg: 'Invalid default value for double: "$str"',
          );
        }
        return str;

      case 'DateTime':
        final str = value.toString();
        // Recognized PostgreSQL/SQL function calls pass through verbatim.
        const passthrough = {
          'NOW()',
          'CURRENT_TIMESTAMP',
          'CURRENT_DATE',
          'CURRENT_TIME',
        };
        if (passthrough.contains(str.toUpperCase())) {
          return str.toUpperCase();
        }
        // Otherwise treat as a quoted literal.
        return str.safe;

      default:
        // String-like default. Quote it.
        return value.toString().safe;
    }
  }
}
