/// Emit PostgreSQL `CREATE TABLE` / `DROP TABLE` SQL for a parsed
/// [SchemaDefinition]. The output is what gets written to
/// `*.up.sql`/`*.down.sql` next to the `.g.dart` file.
library gisila.generators.codegen.sql_emitter;

import 'package:gisila_orm/database/postgres/types/vector.dart';
import 'package:gisila_orm/database/types.dart';
import 'package:gisila_orm/generators/schema_parser.dart';

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

  for (final model in schema.models) {
    buf
      ..writeln(_createTableSql(model))
      ..writeln();
  }

  // Junction tables for many-to-many relations. We skip a junction if
  // the inverse direction in the same schema would also generate it.
  final emittedJunctions = <String>{};
  for (final rel in schema.relationships.where((r) => r.isManyToMany)) {
    final junction = rel.junctionTableName;
    if (junction.isEmpty || !emittedJunctions.add(junction)) continue;
    buf
      ..writeln(_junctionTableSql(rel))
      ..writeln();
  }

  // Foreign-key constraints must be added only after every table
  // exists, otherwise cyclic/table-order dependencies break migration
  // application.
  for (final model in schema.models) {
    final fkSql = _foreignKeyConstraintSql(model);
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
    final dropFkSql = _dropForeignKeyConstraintSql(model);
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
    buf.writeln('DROP TABLE IF EXISTS "${model.tableName}" CASCADE;');
  }

  buf
    ..writeln()
    ..writeln('COMMIT;');
  return buf.toString();
}

String _createTableSql(ModelDefinition model) {
  final buf = StringBuffer('CREATE TABLE "${model.tableName}" (\n');
  final pieces = <String>[];

  for (final col in model.columns) {
    if (col.type == ColumnType.manyToMany) continue;
    pieces.add('  ${_columnDefSql(col, model)}');
  }

  buf
    ..writeln(pieces.join(',\n'))
    ..writeln(');');

  return buf.toString();
}

String _foreignKeyConstraintSql(ModelDefinition model) {
  final buf = StringBuffer();
  for (final col in model.foreignKeyColumns) {
    final ref = col.relationship!.references!;
    final fkColumn = '${col.name}_id';
    final refTable = _toSnakeCase(ref);
    buf.writeln(
      'ALTER TABLE "${model.tableName}" '
      'ADD CONSTRAINT "${model.tableName}_${col.name}_fkey" '
      'FOREIGN KEY ("$fkColumn") REFERENCES "$refTable" ("id") '
      'ON DELETE ${col.relationship!.onDelete ?? 'SET NULL'} '
      'ON UPDATE ${col.relationship!.onUpdate ?? 'CASCADE'};',
    );
  }
  return buf.toString().trimRight();
}

String _dropForeignKeyConstraintSql(ModelDefinition model) {
  final buf = StringBuffer();
  for (final col in model.foreignKeyColumns) {
    buf.writeln(
      'ALTER TABLE "${model.tableName}" '
      'DROP CONSTRAINT IF EXISTS "${model.tableName}_${col.name}_fkey";',
    );
  }
  return buf.toString().trimRight();
}

String _columnDefSql(ColumnDefinition col, ModelDefinition model) {
  // Foreign-key columns are stored as <name>_id INTEGER.
  if (col.type == ColumnType.foreignKey) {
    final nullable = col.constraints.isNull ? '' : ' NOT NULL';
    return '"${col.name}_id" INTEGER$nullable';
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
    final formatted = DefaultEngine.instance.formatForSql(
      col.constraints.defaultValue,
      col.dartType.replaceAll('?', ''),
    );
    buf.write(' DEFAULT $formatted');
  }

  return buf.toString();
}

String _junctionTableSql(RelationshipInfo rel) {
  final left = _toSnakeCase(rel.fromModel);
  final right = _toSnakeCase(rel.toModel);
  return '''CREATE TABLE "${rel.junctionTableName}" (
  "${left}_id" INTEGER NOT NULL,
  "${right}_id" INTEGER NOT NULL,
  "created_at" TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("${left}_id", "${right}_id"),
  FOREIGN KEY ("${left}_id") REFERENCES "$left" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("${right}_id") REFERENCES "$right" ("id") ON DELETE CASCADE
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

    final colName =
        col.type == ColumnType.foreignKey ? '${col.name}_id' : col.name;
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
      final colName = idx.columns.single;
      final ownerCol = colByName[colName];
      final distance = idx.distance ??
          ownerCol?.vector?.distance ??
          VectorDistance.l2;
      final method = idx.using!.name;
      buf.writeln(
        'CREATE INDEX "${idx.name}" ON "${model.tableName}" '
        'USING $method ("$colName" ${distance.opclass});',
      );
      continue;
    }

    final unique = idx.isUnique ? 'UNIQUE ' : '';
    final cols = idx.columns.map((c) => '"$c"').join(', ');
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
