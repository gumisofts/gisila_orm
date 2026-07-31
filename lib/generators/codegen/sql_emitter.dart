/// Emit PostgreSQL `CREATE TABLE` / `DROP TABLE` SQL for a parsed
/// [SchemaDefinition]. The output is what gets written to
/// `*.up.sql`/`*.down.sql` next to the `.g.dart` file.
library gisila.generators.codegen.sql_emitter;

import 'package:gisila_orm/database/postgres/types/vector.dart';
import 'package:gisila_orm/database/types.dart';
import 'package:gisila_orm/generators/schema_parser.dart';

String _resolvedTable(String modelName, SchemaDefinition schema) =>
    schema.getModel(modelName)?.tableName ??
    _pluralSnakeCase(_toSnakeCase(modelName));

/// Primary key of the model named [modelName], or `null` if the model
/// doesn't exist (shouldn't happen once schema validation passes -
/// `unknown_reference` catches dangling references first).
ColumnDefinition? _primaryKeyOf(String modelName, SchemaDefinition schema) =>
    schema.getModel(modelName)?.primaryKey;

String _pluralSnakeCase(String s) {
  if (s.endsWith('s') ||
      s.endsWith('x') ||
      s.endsWith('z') ||
      s.endsWith('ch') ||
      s.endsWith('sh')) {
    return '${s}es';
  }
  if (s.endsWith('y') && s.length > 1 && !'aeiou'.contains(s[s.length - 2])) {
    return '${s.substring(0, s.length - 1)}ies';
  }
  return '${s}s';
}

/// Whether any model declares a vector column or vector index. Used to
/// decide whether to ship a `CREATE EXTENSION IF NOT EXISTS vector;`
/// line at the top of the migration.
bool _schemaUsesVectors(SchemaDefinition schema) {
  for (final model in schema.models) {
    for (final col in model.columns) {
      if (col.type == ColumnType.vector) return true;
    }
    for (final idx in model.indexes) {
      if (idx.using != null) return true;
    }
  }
  return false;
}

/// Generate a single string containing all `CREATE TABLE` statements,
/// then foreign-key constraints, then indexes.
String emitUpSql(SchemaDefinition schema) {
  final buf = StringBuffer()
    ..writeln('-- gisila-generated migration: up')
    ..writeln('-- DO NOT EDIT - regenerate via `dart run build_runner build`')
    ..writeln()
    ..writeln('BEGIN;')
    ..writeln();

  if (_schemaUsesVectors(schema)) {
    buf
      ..writeln('CREATE EXTENSION IF NOT EXISTS vector;')
      ..writeln();
  }

  for (final e in schema.enums) {
    final values = e.values.map((v) => "'$v'").join(', ');
    buf
      ..writeln(
          'CREATE TYPE "${e.postgresTypeName}" AS ENUM ($values);')
      ..writeln();
  }

  for (final model in schema.models) {
    buf
      ..writeln(_createTableSql(model, schema))
      ..writeln();
  }

  // Junction tables for many-to-many relations. We skip a junction if
  // the inverse direction in the same schema would also generate it.
  final emittedJunctions = <String>{};
  for (final rel in schema.relationships.where((r) => r.isManyToMany)) {
    final junction = rel.junctionTableName;
    if (junction.isEmpty || !emittedJunctions.add(junction)) continue;
    buf
      ..writeln(_junctionTableSql(rel, schema))
      ..writeln();
  }

  // Foreign-key constraints must be added only after every table
  // exists, otherwise cyclic/table-order dependencies break migration
  // application.
  for (final model in schema.models) {
    final fkSql = _foreignKeyConstraintSql(model, schema);
    if (fkSql.isNotEmpty) {
      buf
        ..writeln(fkSql)
        ..writeln();
    }
  }

  // Indexes
  for (final model in schema.models) {
    final idx = _indexSql(model);
    if (idx.isNotEmpty) {
      buf
        ..writeln(idx)
        ..writeln();
    }
  }

  // Named table-level CHECK constraints (column-level CHECKs are inline).
  for (final model in schema.models) {
    for (final check in model.checks) {
      buf.writeln(
        'ALTER TABLE "${model.tableName}" '
        'ADD CONSTRAINT "${check.name}" CHECK (${check.expression});',
      );
    }
    if (model.checks.isNotEmpty) buf.writeln();
  }

  buf.writeln('COMMIT;');
  return buf.toString();
}

/// Generate the rollback for [emitUpSql].
///
/// Order is intentionally:
/// 1) Drop foreign-key constraints
/// 2) Drop tables
String emitDownSql(SchemaDefinition schema) {
  final buf = StringBuffer()
    ..writeln('-- gisila-generated migration: down')
    ..writeln('-- DO NOT EDIT - regenerate via `dart run build_runner build`')
    ..writeln()
    ..writeln('BEGIN;')
    ..writeln();

  for (final model in schema.models.reversed) {
    final dropFkSql = _dropForeignKeyConstraintSql(model, schema);
    if (dropFkSql.isNotEmpty) {
      buf.writeln(dropFkSql);
    }
  }

  final emittedJunctions = <String>{};
  for (final rel in schema.relationships.where((r) => r.isManyToMany)) {
    final junction = rel.junctionTableName;
    if (junction.isEmpty || !emittedJunctions.add(junction)) continue;
    buf.writeln('DROP TABLE IF EXISTS "$junction" CASCADE;');
  }

  for (final model in schema.models.reversed) {
    for (final check in model.checks.reversed) {
      buf.writeln(
        'ALTER TABLE "${model.tableName}" '
        'DROP CONSTRAINT IF EXISTS "${check.name}";',
      );
    }
    buf.writeln('DROP TABLE IF EXISTS "${model.tableName}" CASCADE;');
  }

  for (final e in schema.enums.reversed) {
    buf.writeln('DROP TYPE IF EXISTS "${e.postgresTypeName}";');
  }

  buf
    ..writeln()
    ..writeln('COMMIT;');
  return buf.toString();
}

String _createTableSql(ModelDefinition model, SchemaDefinition schema) {
  final buf = StringBuffer('CREATE TABLE "${model.tableName}" (\n');
  final pieces = <String>[];

  for (final col in model.columns) {
    if (col.type == ColumnType.manyToMany) continue;
    pieces.add('  ${_columnDefSql(col, model, schema)}');
  }

  // Inline column-level CHECKs as table constraints for stable names.
  for (final col in model.columns) {
    final expr = col.checkExpression;
    if (expr == null || expr.isEmpty) continue;
    final name = '${model.tableName}_${col.name}_check';
    pieces.add('  CONSTRAINT "$name" CHECK ($expr)');
  }

  buf
    ..writeln(pieces.join(',\n'))
    ..writeln(');');

  return buf.toString();
}

String _foreignKeyConstraintSql(
    ModelDefinition model, SchemaDefinition schema) {
  final buf = StringBuffer();
  for (final col in model.foreignKeyColumns) {
    final ref = col.relationship!.references!;
    final fkColumn = col.physicalColumnName;
    final refTable = _resolvedTable(ref, schema);
    final refPkName = _primaryKeyOf(ref, schema)?.name ?? 'id';
    buf.writeln(
      'ALTER TABLE "${model.tableName}" '
      'ADD CONSTRAINT "${model.tableName}_${col.name}_fkey" '
      'FOREIGN KEY ("$fkColumn") REFERENCES "$refTable" ("$refPkName") '
      'ON DELETE ${col.relationship!.onDelete ?? 'SET NULL'} '
      'ON UPDATE ${col.relationship!.onUpdate ?? 'CASCADE'};',
    );
  }
  return buf.toString().trimRight();
}

String _dropForeignKeyConstraintSql(
    ModelDefinition model, SchemaDefinition schema) {
  final buf = StringBuffer();
  for (final col in model.foreignKeyColumns) {
    buf.writeln(
      'ALTER TABLE "${model.tableName}" '
      'DROP CONSTRAINT IF EXISTS "${model.tableName}_${col.name}_fkey";',
    );
  }
  return buf.toString().trimRight();
}

String _columnDefSql(
    ColumnDefinition col, ModelDefinition model, SchemaDefinition schema) {
  // Foreign-key columns are stored as `<name>_id` (or `<name>` when it
  // already ends with `_id`), typed to match whatever the referenced
  // model's primary key actually is (INTEGER PKs are BIGSERIAL under
  // the hood, hence `effectivePostgresType`).
  if (col.type == ColumnType.foreignKey) {
    final nullable = col.constraints.isNull ? '' : ' NOT NULL';
    final unique = col.constraints.isUnique ? ' UNIQUE' : '';
    final refPk = _primaryKeyOf(col.relationship!.references!, schema);
    final refType = refPk?.effectivePostgresType ?? 'BIGINT';
    return '"${col.physicalColumnName}" $refType$nullable$unique';
  }

  final buf = StringBuffer('"${col.name}" ');
  if (col.constraints.isPrimary) {
    // Use BIGSERIAL for implicit integer primary keys, otherwise the
    // declared type.
    if (col.type == ColumnType.integer || col.type == ColumnType.bigint) {
      buf.write('BIGSERIAL PRIMARY KEY');
      return buf.toString();
    }
    buf
      ..write(col.postgresType)
      ..write(' PRIMARY KEY');
  } else {
    buf.write(col.postgresType);
    if (!col.constraints.isNull) buf.write(' NOT NULL');
    if (col.constraints.isUnique) buf.write(' UNIQUE');
  }

  if (col.constraints.defaultValue != null) {
    final formatted = _formatColumnDefault(col, model);
    buf.write(' DEFAULT $formatted');
  }

  return buf.toString();
}

String _formatColumnDefault(ColumnDefinition col, ModelDefinition model) {
  final label = '${model.name}.${col.name}';
  final value = col.constraints.defaultValue;
  if (col.type == ColumnType.enumType) {
    final enumType = col.enumConfig!.postgresTypeName;
    final lit = value.toString().replaceAll("'", "''");
    return "'$lit'::$enumType";
  }
  if (col.type == ColumnType.array) {
    return DefaultEngine.instance.formatArrayDefault(
      value,
      col.array!.pgCast,
      columnLabel: label,
    );
  }
  if (col.type == ColumnType.point ||
      col.type == ColumnType.box ||
      col.type == ColumnType.circle ||
      col.type == ColumnType.lseg) {
    final cast = col.type.name;
    final lit = value.toString().replaceAll("'", "''");
    return "'$lit'::$cast";
  }
  return DefaultEngine.instance.formatForSql(
    value,
    col.dartType.replaceAll('?', ''),
    columnLabel: label,
  );
}

/// Resolve a logical YAML column name (as used in `indexes:`) to the
/// physical SQL column name, rewriting foreign keys to their `_id` form.
String _physicalIndexColumn(String logicalName, ModelDefinition model) {
  final col = model.columns.where((c) => c.name == logicalName).firstOrNull;
  if (col == null) return logicalName;
  return col.physicalColumnName;
}

String _junctionTableSql(RelationshipInfo rel, SchemaDefinition schema) {
  final left = _resolvedTable(rel.fromModel, schema);
  final right = _resolvedTable(rel.toModel, schema);
  final leftPk = _primaryKeyOf(rel.fromModel, schema);
  final rightPk = _primaryKeyOf(rel.toModel, schema);
  final leftType = leftPk?.effectivePostgresType ?? 'BIGINT';
  final rightType = rightPk?.effectivePostgresType ?? 'BIGINT';
  final leftPkName = leftPk?.name ?? 'id';
  final rightPkName = rightPk?.name ?? 'id';
  return '''CREATE TABLE "${rel.junctionTableName}" (
  "${left}_id" $leftType NOT NULL,
  "${right}_id" $rightType NOT NULL,
  "created_at" TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("${left}_id", "${right}_id"),
  FOREIGN KEY ("${left}_id") REFERENCES "$left" ("$leftPkName") ON DELETE CASCADE,
  FOREIGN KEY ("${right}_id") REFERENCES "$right" ("$rightPkName") ON DELETE CASCADE
);''';
}

String _indexSql(ModelDefinition model) {
  final buf = StringBuffer();

  // Implicit indexes on `is_index: true` columns (skip primary key,
  // already indexed; skip unique, also implicit).
  for (final col in model.columns) {
    if (!col.constraints.isIndex) continue;
    if (col.constraints.isPrimary) continue;
    if (col.constraints.isUnique) continue;
    if (col.type == ColumnType.manyToMany) continue;

    final colName = col.physicalColumnName;
    final idxName = 'idx_${model.tableName}_$colName';

    if (col.type == ColumnType.vector) {
      final cfg = col.vector ?? const VectorConfig(dimensions: 0);
      final method = cfg.indexMethod.name;
      final opclass = cfg.distance.opclass;
      buf.writeln(
        'CREATE INDEX "$idxName" ON "${model.tableName}" '
        'USING $method ("$colName" $opclass);',
      );
      continue;
    }

    buf.writeln(
      'CREATE INDEX "$idxName" ON "${model.tableName}" ("$colName");',
    );
  }

  // Explicit indexes from the schema's `indexes:` block.
  final colByName = {for (final c in model.columns) c.name: c};
  for (final idx in model.indexes) {
    if (idx.using != null) {
      // pgvector index: a single column + a `USING <method> (col opclass)`.
      if (idx.columns.length != 1) {
        // Multi-column vector indexes are not supported; fall back to
        // emitting nothing rather than producing invalid SQL.
        continue;
      }
      final logicalName = idx.columns.single;
      final colName = _physicalIndexColumn(logicalName, model);
      final ownerCol = colByName[logicalName];
      final distance =
          idx.distance ?? ownerCol?.vector?.distance ?? VectorDistance.l2;
      final method = idx.using!.name;
      buf.writeln(
        'CREATE INDEX "${idx.name}" ON "${model.tableName}" '
        'USING $method ("$colName" ${distance.opclass});',
      );
      continue;
    }

    final unique = idx.isUnique ? 'UNIQUE ' : '';
    final cols = idx.columns
        .map((c) => '"${_physicalIndexColumn(c, model)}"')
        .join(', ');
    buf.writeln(
      'CREATE ${unique}INDEX "${idx.name}" ON "${model.tableName}" ($cols);',
    );
  }

  return buf.toString().trimRight();
}

String _toSnakeCase(String s) => s
    .replaceAllMapped(
      RegExp(r'[A-Z]'),
      (m) => '_${m.group(0)!.toLowerCase()}',
    )
    .replaceFirst(RegExp(r'^_'), '');
