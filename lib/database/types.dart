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

  /// Matches a bare or schema-qualified SQL function call, e.g.
  /// `NOW()`, `gen_random_uuid()`, `uuid_generate_v4()`,
  /// `myschema.next_id()`, or `nextval('seq')::int`. Any YAML default
  /// value shaped like this is passed through verbatim rather than
  /// quoted, regardless of the column's declared Dart type - this is
  /// what lets `type: uuid` columns use `default: gen_random_uuid()`.
  static final RegExp _functionCallPattern = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)*\s*\([^()]*\)'
    r'(::[A-Za-z_][A-Za-z0-9_. \[\]"]*)?$',
  );

  /// Format a YAML-supplied default `value` for a column whose Dart
  /// type name is [dartType] (e.g. `'int'`, `'String'`, `'bool'`).
  ///
  /// [columnLabel], when provided (e.g. `'User.is_active'`), is folded
  /// into the thrown [DefaultValueException.msg] so build failures point
  /// straight at the offending column instead of just naming the bad
  /// literal.
  ///
  /// Returns a SQL literal suitable to drop into `DEFAULT <literal>`.
  /// Throws [DefaultValueException] for invalid combinations.
  String formatForSql(dynamic value, String dartType, {String? columnLabel}) {
    if (value == null) return 'NULL';

    if (value is String) {
      final trimmed = value.trim();
      if (_functionCallPattern.hasMatch(trimmed)) {
        return trimmed;
      }
    }

    Never fail(String detail, {required String fix}) {
      final where = columnLabel != null ? ' on column "$columnLabel"' : '';
      throw DefaultValueException(
        msg: 'Invalid `default`$where: $detail. $fix',
      );
    }

    switch (dartType) {
      case 'bool':
        final str = value.toString();
        if (str != 'true' && str != 'false') {
          fail(
            'expected a boolean but got ${value.runtimeType} "$str"',
            fix: 'use `default: true` or `default: false`.',
          );
        }
        return str.toUpperCase();

      case 'int':
        if (value is int) return value.toString();
        final str = value.toString();
        if (!RegExp(r'^-?\d+$').hasMatch(str)) {
          fail(
            'expected a whole number but got "$str"',
            fix: 'use a bare integer (e.g. `default: 0`) or a SQL '
                'function call (e.g. `default: nextval(\'my_seq\')`).',
          );
        }
        return str;

      case 'double':
        if (value is num) return value.toString();
        final str = value.toString();
        if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(str)) {
          fail(
            'expected a number but got "$str"',
            fix: 'use a bare number (e.g. `default: 0.0`).',
          );
        }
        return str;

      case 'DateTime':
        final str = value.toString().trim();
        // Recognized PostgreSQL/SQL function calls and common aliases
        // (`now`, `NOW`, `current_timestamp`, …) pass through verbatim.
        const functionPassthrough = {
          'NOW()',
          'CURRENT_TIMESTAMP',
          'CURRENT_DATE',
          'CURRENT_TIME',
        };
        const aliasPassthrough = {
          'NOW': 'NOW()',
          'CURRENT_TIMESTAMP': 'CURRENT_TIMESTAMP',
          'CURRENT_DATE': 'CURRENT_DATE',
          'CURRENT_TIME': 'CURRENT_TIME',
        };
        final upper = str.toUpperCase();
        if (functionPassthrough.contains(upper)) {
          return upper;
        }
        final aliased = aliasPassthrough[upper];
        if (aliased != null) {
          return aliased;
        }
        // Otherwise treat as a quoted literal.
        return str.safe;

      default:
        // String-like default (varchar/text/uuid/...). Anything that
        // isn't a recognized SQL function call (handled above) is
        // treated as a literal and quoted.
        return value.toString().safe;
    }
  }

  /// Format a YAML default for a Postgres array column.
  ///
  /// Accepts `'{}'`, `'{a,b}'`, or a YAML list of scalars.
  /// [pgCast] is the Postgres cast target (e.g. `varchar[]`, `integer[]`).
  String formatArrayDefault(
    dynamic value,
    String pgCast, {
    String? columnLabel,
  }) {
    Never fail(String detail, {required String fix}) {
      final where = columnLabel != null ? ' on column "$columnLabel"' : '';
      throw DefaultValueException(
        msg: 'Invalid `default`$where: $detail. $fix',
      );
    }

    if (value is List) {
      final parts = value.map((e) {
        if (e is num || e is bool) return e.toString();
        final s = e.toString().replaceAll('"', '\\"');
        return '"$s"';
      }).join(',');
      return "'{$parts}'::$pgCast";
    }

    if (value is String) {
      final trimmed = value.trim();
      if (trimmed == '{}' ||
          (trimmed.startsWith('{') && trimmed.endsWith('}'))) {
        return "'$trimmed'::$pgCast";
      }
      fail(
        'expected an array literal like `{}` or `{a,b}`, or a YAML list',
        fix: 'use `default: \'{}\'` or `default: [a, b]`.',
      );
    }

    fail(
      'expected a string array literal or YAML list, got ${value.runtimeType}',
      fix: 'use `default: \'{}\'` or `default: [1, 2]`.',
    );
  }
}
