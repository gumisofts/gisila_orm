/// Schema differ for gisila_orm: compares two parsed schemas and emits a
/// list of [SchemaChange]s with paired up/down SQL.
///
/// The differ is intentionally heuristic: column renames are detected
/// only when an old column disappears and a single new column with the
/// same SQL type and nullability appears in the same table. Anything
/// more ambiguous is reported as a drop+add and the migration author
/// is expected to edit the generated SQL by hand.
library gisila.migrations.schema_differ;

import 'dart:async';
import 'dart:io';
import 'package:gisila_orm/database/postgres/types/vector.dart';
import 'package:gisila_orm/generators/schema_parser.dart';

/// Double-quote a PostgreSQL identifier so reserved words (`desc`, `user`,
/// `order`, …) and mixed-case names match `sql_emitter` output.
String _quoteIdent(String ident) => '"${ident.replaceAll('"', '""')}"';

/// Types of schema changes
enum ChangeType {
  createTable,
  dropTable,
  renameTable,
  addColumn,
  dropColumn,
  modifyColumn,
  renameColumn,
  addIndex,
  dropIndex,
  addForeignKey,
  dropForeignKey,
}

/// Represents a single schema change
class SchemaChange {
  final ChangeType type;
  final String? tableName;
  final String? columnName;
  final String? oldName;
  final String? newName;
  final Map<String, dynamic>? metadata;

  const SchemaChange({
    required this.type,
    this.tableName,
    this.columnName,
    this.oldName,
    this.newName,
    this.metadata,
  });

  @override
  String toString() {
    switch (type) {
      case ChangeType.createTable:
        return 'Create table: $tableName';
      case ChangeType.dropTable:
        return 'Drop table: $tableName';
      case ChangeType.renameTable:
        return 'Rename table: $oldName → $newName';
      case ChangeType.addColumn:
        return 'Add column: $tableName.$columnName';
      case ChangeType.dropColumn:
        return 'Drop column: $tableName.$columnName';
      case ChangeType.modifyColumn:
        return 'Modify column: $tableName.$columnName';
      case ChangeType.renameColumn:
        return 'Rename column: $tableName.$oldName → $newName';
      case ChangeType.addIndex:
        return 'Add index: $tableName';
      case ChangeType.dropIndex:
        return 'Drop index: $tableName';
      case ChangeType.addForeignKey:
        return 'Add foreign key: $tableName.$columnName';
      case ChangeType.dropForeignKey:
        return 'Drop foreign key: $tableName.$columnName';
    }
  }
}

/// Migration operation
class MigrationOperation {
  final String upSql;
  final String downSql;
  final SchemaChange change;

  const MigrationOperation({
    required this.upSql,
    required this.downSql,
    required this.change,
  });
}

/// Schema comparison result
class SchemaDiff {
  final List<SchemaChange> changes;
  final List<MigrationOperation> operations;
  final bool hasDestructiveChanges;

  const SchemaDiff({
    required this.changes,
    required this.operations,
    required this.hasDestructiveChanges,
  });

  bool get isEmpty => changes.isEmpty;
  bool get isNotEmpty => changes.isNotEmpty;
}

/// Schema differ class
class SchemaDiffer {
  /// Compare two schemas and generate diff
  SchemaDiff compareSchemas(
      SchemaDefinition oldSchema, SchemaDefinition newSchema) {
    final changes = <SchemaChange>[];
    final operations = <MigrationOperation>[];

    // Build lookup maps
    final oldModels = <String, ModelDefinition>{};
    final newModels = <String, ModelDefinition>{};

    for (final model in oldSchema.models) {
      oldModels[model.name] = model;
    }

    for (final model in newSchema.models) {
      newModels[model.name] = model;
    }

    // If the old schema had no vector columns/indexes but the new
    // schema does, the pgvector extension may not be installed on the
    // target database. Emit `CREATE EXTENSION IF NOT EXISTS vector;`
    // as the first operation so subsequent VECTOR(...) DDL succeeds.
    if (!_schemaUsesVectors(oldSchema) && _schemaUsesVectors(newSchema)) {
      operations.add(const MigrationOperation(
        upSql: 'CREATE EXTENSION IF NOT EXISTS vector;',
        // Don't DROP EXTENSION on rollback: other apps/tables may rely
        // on pgvector. Rolling back to a schema without vectors should
        // leave the extension installed; the dropped vector columns
        // already release any data dependency on it.
        downSql: '-- pgvector extension intentionally left installed',
        change: SchemaChange(
          type: ChangeType.createTable,
          tableName: 'EXTENSION vector',
        ),
      ));
    }

    // Find table changes
    _compareModels(oldModels, newModels, changes, operations);

    // Check for destructive changes
    final hasDestructive = changes.any((change) =>
        change.type == ChangeType.dropTable ||
        change.type == ChangeType.dropColumn ||
        change.type == ChangeType.modifyColumn);

    return SchemaDiff(
      changes: changes,
      operations: operations,
      hasDestructiveChanges: hasDestructive,
    );
  }

  /// Does any model in [schema] declare a vector column or vector index?
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

  /// Compare models (tables)
  void _compareModels(
    Map<String, ModelDefinition> oldModels,
    Map<String, ModelDefinition> newModels,
    List<SchemaChange> changes,
    List<MigrationOperation> operations,
  ) {
    // Dropped tables
    for (final oldModel in oldModels.values) {
      if (!newModels.containsKey(oldModel.name)) {
        final change = SchemaChange(
          type: ChangeType.dropTable,
          tableName: oldModel.tableName,
        );
        changes.add(change);
        operations.add(_generateDropTableOperation(oldModel, change));
      }
    }

    // New tables
    for (final newModel in newModels.values) {
      if (!oldModels.containsKey(newModel.name)) {
        final change = SchemaChange(
          type: ChangeType.createTable,
          tableName: newModel.tableName,
        );
        changes.add(change);
        operations.add(_generateCreateTableOperation(newModel, change));
      }
    }

    // Modified tables
    for (final newModel in newModels.values) {
      final oldModel = oldModels[newModel.name];
      if (oldModel != null) {
        // Check for table rename
        if (oldModel.tableName != newModel.tableName) {
          final change = SchemaChange(
            type: ChangeType.renameTable,
            oldName: oldModel.tableName,
            newName: newModel.tableName,
          );
          changes.add(change);
          operations
              .add(_generateRenameTableOperation(oldModel, newModel, change));
        }

        // Compare columns
        _compareColumns(oldModel, newModel, changes, operations);

        // Compare indexes
        _compareIndexes(oldModel, newModel, changes, operations);
      }
    }
  }

  /// Compare columns
  void _compareColumns(
    ModelDefinition oldModel,
    ModelDefinition newModel,
    List<SchemaChange> changes,
    List<MigrationOperation> operations,
  ) {
    final oldColumns = <String, ColumnDefinition>{};
    final newColumns = <String, ColumnDefinition>{};

    for (final col in oldModel.columns) {
      oldColumns[col.name] = col;
    }

    for (final col in newModel.columns) {
      newColumns[col.name] = col;
    }

    // 1. Identify candidate dropped/added columns up-front so we can
    //    spot rename patterns before falling back to drop+add.
    final droppedNames =
        oldColumns.keys.where((n) => !newColumns.containsKey(n)).toList();
    final addedNames =
        newColumns.keys.where((n) => !oldColumns.containsKey(n)).toList();

    final renames = <_RenamePair>[];
    for (final dropped in List<String>.from(droppedNames)) {
      // A rename match: exactly one added column shares the dropped
      // column's SQL type AND nullability AND is not already claimed.
      final candidates = addedNames
          .where((n) => !renames.any((r) => r.newName == n))
          .where((n) =>
              _columnsLookCompatible(oldColumns[dropped]!, newColumns[n]!))
          .toList();
      if (candidates.length == 1) {
        renames.add(_RenamePair(oldName: dropped, newName: candidates.single));
      }
    }
    final renamedOldNames = renames.map((r) => r.oldName).toSet();
    final renamedNewNames = renames.map((r) => r.newName).toSet();

    // 2. Emit rename ops first so they take precedence over drop+add.
    for (final r in renames) {
      final change = SchemaChange(
        type: ChangeType.renameColumn,
        tableName: newModel.tableName,
        oldName: r.oldName,
        newName: r.newName,
      );
      changes.add(change);
      operations.add(_generateRenameColumnOperation(newModel, r, change));
    }

    // 3. Real drops (anything that wasn't matched as a rename).
    for (final dropped in droppedNames) {
      if (renamedOldNames.contains(dropped)) continue;
      final oldCol = oldColumns[dropped]!;
      final change = SchemaChange(
        type: ChangeType.dropColumn,
        tableName: newModel.tableName,
        columnName: dropped,
      );
      changes.add(change);
      operations.add(_generateDropColumnOperation(newModel, oldCol, change));
      if (oldCol.type == ColumnType.foreignKey) {
        final fkChange = SchemaChange(
          type: ChangeType.dropForeignKey,
          tableName: newModel.tableName,
          columnName: dropped,
        );
        changes.add(fkChange);
        operations
            .add(_generateDropForeignKeyOperation(newModel, oldCol, fkChange));
      }
    }

    // 4. Real adds.
    for (final added in addedNames) {
      if (renamedNewNames.contains(added)) continue;
      final newCol = newColumns[added]!;
      final change = SchemaChange(
        type: ChangeType.addColumn,
        tableName: newModel.tableName,
        columnName: added,
      );
      changes.add(change);
      operations.add(_generateAddColumnOperation(newModel, newCol, change));
      if (newCol.type == ColumnType.foreignKey) {
        final fkChange = SchemaChange(
          type: ChangeType.addForeignKey,
          tableName: newModel.tableName,
          columnName: added,
        );
        changes.add(fkChange);
        operations
            .add(_generateAddForeignKeyOperation(newModel, newCol, fkChange));
      }
    }

    // 5. In-place modifications.
    for (final newCol in newColumns.values) {
      final oldCol = oldColumns[newCol.name];
      if (oldCol != null && _isColumnModified(oldCol, newCol)) {
        final change = SchemaChange(
          type: ChangeType.modifyColumn,
          tableName: newModel.tableName,
          columnName: newCol.name,
          metadata: {
            'oldColumn': oldCol,
            'newColumn': newCol,
          },
        );
        changes.add(change);
        operations.add(
            _generateModifyColumnOperation(newModel, oldCol, newCol, change));
      }
    }
  }

  /// Heuristic used by the rename detector. Two columns are
  /// "compatible" for a rename when they share the same Postgres type
  /// signature and nullability/uniqueness profile.
  bool _columnsLookCompatible(ColumnDefinition a, ColumnDefinition b) {
    if (a.type != b.type) return false;
    if (a.postgresType != b.postgresType) return false;
    if (a.constraints.isNull != b.constraints.isNull) return false;
    if (a.constraints.isPrimary != b.constraints.isPrimary) return false;
    return true;
  }

  /// Compare indexes
  void _compareIndexes(
    ModelDefinition oldModel,
    ModelDefinition newModel,
    List<SchemaChange> changes,
    List<MigrationOperation> operations,
  ) {
    final oldIndexes = <String, IndexDefinition>{};
    final newIndexes = <String, IndexDefinition>{};

    for (final idx in oldModel.indexes) {
      oldIndexes[idx.name] = idx;
    }

    for (final idx in newModel.indexes) {
      newIndexes[idx.name] = idx;
    }

    // Dropped indexes
    for (final oldIdx in oldIndexes.values) {
      if (!newIndexes.containsKey(oldIdx.name)) {
        final change = SchemaChange(
          type: ChangeType.dropIndex,
          tableName: newModel.tableName,
          columnName: oldIdx.name,
        );
        changes.add(change);
        operations.add(_generateDropIndexOperation(newModel, oldIdx, change));
      }
    }

    // New indexes
    for (final newIdx in newIndexes.values) {
      if (!oldIndexes.containsKey(newIdx.name)) {
        final change = SchemaChange(
          type: ChangeType.addIndex,
          tableName: newModel.tableName,
          columnName: newIdx.name,
        );
        changes.add(change);
        operations.add(_generateAddIndexOperation(newModel, newIdx, change));
      }
    }
  }

  /// Check if column is modified
  bool _isColumnModified(ColumnDefinition oldCol, ColumnDefinition newCol) {
    if (oldCol.type != newCol.type ||
        oldCol.constraints.isNull != newCol.constraints.isNull ||
        oldCol.constraints.isUnique != newCol.constraints.isUnique ||
        oldCol.constraints.isPrimary != newCol.constraints.isPrimary ||
        oldCol.constraints.defaultValue != newCol.constraints.defaultValue) {
      return true;
    }
    // Vector-specific shape changes also need a migration: the
    // declared type carries the dimensions (`VECTOR(n)`), so we have
    // to detect changes to `dimensions`, and an index method or
    // distance flip means dropping/re-creating the index.
    if (oldCol.type == ColumnType.vector && newCol.type == ColumnType.vector) {
      if (oldCol.postgresType != newCol.postgresType) return true;
      final ov = oldCol.vector;
      final nv = newCol.vector;
      if (ov?.indexMethod != nv?.indexMethod) return true;
      if (ov?.distance != nv?.distance) return true;
      if (oldCol.constraints.isIndex != newCol.constraints.isIndex) return true;
    }
    return false;
  }

  // Migration operation generators

  MigrationOperation _generateCreateTableOperation(
      ModelDefinition model, SchemaChange change) {
    final upSql = _generateCreateTableSql(model);
    final downSql = 'DROP TABLE IF EXISTS ${_quoteIdent(model.tableName)};';

    return MigrationOperation(
      upSql: upSql,
      downSql: downSql,
      change: change,
    );
  }

  MigrationOperation _generateDropTableOperation(
      ModelDefinition model, SchemaChange change) {
    final upSql = 'DROP TABLE IF EXISTS ${_quoteIdent(model.tableName)};';
    final downSql = _generateCreateTableSql(model);

    return MigrationOperation(
      upSql: upSql,
      downSql: downSql,
      change: change,
    );
  }

  MigrationOperation _generateRenameTableOperation(
      ModelDefinition oldModel, ModelDefinition newModel, SchemaChange change) {
    final upSql =
        'ALTER TABLE ${_quoteIdent(oldModel.tableName)} RENAME TO ${_quoteIdent(newModel.tableName)};';
    final downSql =
        'ALTER TABLE ${_quoteIdent(newModel.tableName)} RENAME TO ${_quoteIdent(oldModel.tableName)};';

    return MigrationOperation(
      upSql: upSql,
      downSql: downSql,
      change: change,
    );
  }

  MigrationOperation _generateAddColumnOperation(
      ModelDefinition model, ColumnDefinition column, SchemaChange change) {
    final columnDef = _generateColumnDefinition(column);
    final upStmts = <String>[
      'ALTER TABLE ${_quoteIdent(model.tableName)} ADD COLUMN $columnDef;',
    ];
    final downStmts = <String>[
      'ALTER TABLE ${_quoteIdent(model.tableName)} '
          'DROP COLUMN ${_quoteIdent(column.name)};',
    ];

    // Vector columns marked `is_index: true` need an explicit
    // `CREATE INDEX ... USING <method>` to match what a fresh
    // schema would emit. Without this, adding the column via
    // incremental migration silently drops the pgvector index.
    final implicit = _implicitVectorIndexFor(model, column);
    if (implicit != null) {
      upStmts.add(implicit.upSql);
      downStmts.insert(0, implicit.downSql);
    }

    return MigrationOperation(
      upSql: upStmts.join('\n'),
      downSql: downStmts.join('\n'),
      change: change,
    );
  }

  MigrationOperation _generateDropColumnOperation(
      ModelDefinition model, ColumnDefinition column, SchemaChange change) {
    final columnDef = _generateColumnDefinition(column);
    final upStmts = <String>[];
    final downStmts = <String>[];

    // Mirror image of _generateAddColumnOperation: when dropping a
    // vector column that previously carried an implicit index, drop
    // the index first (some pgvector versions barf if it outlives the
    // column) and re-create it on rollback.
    final implicit = _implicitVectorIndexFor(model, column);
    if (implicit != null) {
      upStmts.add(implicit.downSql);
    }
    upStmts.add(
      'ALTER TABLE ${_quoteIdent(model.tableName)} '
      'DROP COLUMN ${_quoteIdent(column.name)};',
    );

    downStmts.add(
      'ALTER TABLE ${_quoteIdent(model.tableName)} ADD COLUMN $columnDef;',
    );
    if (implicit != null) {
      downStmts.add(implicit.upSql);
    }

    return MigrationOperation(
      upSql: upStmts.join('\n'),
      downSql: downStmts.join('\n'),
      change: change,
    );
  }

  /// If [column] is a vector column with `is_index: true`, return the
  /// matching `CREATE INDEX ... USING <method> (col opclass)` /
  /// `DROP INDEX` pair; otherwise return `null`. We don't emit
  /// implicit btree indexes here to preserve existing behavior - this
  /// is strictly the pgvector special case.
  _ImplicitIndex? _implicitVectorIndexFor(
    ModelDefinition model,
    ColumnDefinition column,
  ) {
    if (column.type != ColumnType.vector) return null;
    if (!column.constraints.isIndex) return null;
    if (column.constraints.isPrimary) return null;
    if (column.constraints.isUnique) return null;
    final cfg = column.vector ?? const VectorConfig(dimensions: 0);
    final idxName = 'idx_${model.tableName}_${column.name}';
    final method = cfg.indexMethod.name;
    final opclass = cfg.distance.opclass;
    final upSql = 'CREATE INDEX ${_quoteIdent(idxName)} '
        'ON ${_quoteIdent(model.tableName)} '
        'USING $method (${_quoteIdent(column.name)} $opclass);';
    final downSql = 'DROP INDEX IF EXISTS ${_quoteIdent(idxName)};';
    return _ImplicitIndex(upSql: upSql, downSql: downSql);
  }

  MigrationOperation _generateModifyColumnOperation(
    ModelDefinition model,
    ColumnDefinition oldColumn,
    ColumnDefinition newColumn,
    SchemaChange change,
  ) {
    final upStmts = <String>[];
    final downStmts = <String>[];

    if (oldColumn.postgresType != newColumn.postgresType) {
      upStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(newColumn.name)} '
        'TYPE ${newColumn.postgresType};',
      );
      downStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(oldColumn.name)} '
        'TYPE ${oldColumn.postgresType};',
      );
    }
    if (oldColumn.constraints.isNull != newColumn.constraints.isNull) {
      final upClause =
          newColumn.constraints.isNull ? 'DROP NOT NULL' : 'SET NOT NULL';
      final downClause =
          oldColumn.constraints.isNull ? 'DROP NOT NULL' : 'SET NOT NULL';
      upStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(newColumn.name)} $upClause;',
      );
      downStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(oldColumn.name)} $downClause;',
      );
    }
    if (oldColumn.constraints.defaultValue !=
        newColumn.constraints.defaultValue) {
      if (newColumn.constraints.defaultValue == null) {
        upStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(newColumn.name)} DROP DEFAULT;',
        );
      } else {
        upStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(newColumn.name)} '
          'SET DEFAULT ${newColumn.constraints.defaultValue};',
        );
      }
      if (oldColumn.constraints.defaultValue == null) {
        downStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(oldColumn.name)} DROP DEFAULT;',
        );
      } else {
        downStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(oldColumn.name)} '
          'SET DEFAULT ${oldColumn.constraints.defaultValue};',
        );
      }
    }

    // Vector index transitions: drop the old implicit index and
    // re-create the new one when `is_index`, `index_method`, or
    // `distance` changed. This is the only way for a user to migrate
    // between HNSW and IVFFlat without dropping the column.
    if (newColumn.type == ColumnType.vector &&
        oldColumn.type == ColumnType.vector) {
      final oldImplicit = _implicitVectorIndexFor(model, oldColumn);
      final newImplicit = _implicitVectorIndexFor(model, newColumn);
      if (oldImplicit?.upSql != newImplicit?.upSql) {
        if (oldImplicit != null) {
          upStmts.add(oldImplicit.downSql);
          downStmts.add(oldImplicit.upSql);
        }
        if (newImplicit != null) {
          upStmts.add(newImplicit.upSql);
          downStmts.add(newImplicit.downSql);
        }
      }
    }

    // Fall back to a TYPE swap if no specific delta was identified
    // (paranoid default; should not normally hit).
    if (upStmts.isEmpty) {
      upStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(newColumn.name)} '
        'TYPE ${newColumn.postgresType};',
      );
      downStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN ${_quoteIdent(oldColumn.name)} '
        'TYPE ${oldColumn.postgresType};',
      );
    }

    return MigrationOperation(
      upSql: upStmts.join('\n'),
      downSql: downStmts.reversed.join('\n'),
      change: change,
    );
  }

  MigrationOperation _generateRenameColumnOperation(
    ModelDefinition model,
    _RenamePair rename,
    SchemaChange change,
  ) {
    final upSql = 'ALTER TABLE ${_quoteIdent(model.tableName)} '
        'RENAME COLUMN ${_quoteIdent(rename.oldName)} TO ${_quoteIdent(rename.newName)};';
    final downSql = 'ALTER TABLE ${_quoteIdent(model.tableName)} '
        'RENAME COLUMN ${_quoteIdent(rename.newName)} TO ${_quoteIdent(rename.oldName)};';
    return MigrationOperation(upSql: upSql, downSql: downSql, change: change);
  }

  MigrationOperation _generateAddForeignKeyOperation(
    ModelDefinition model,
    ColumnDefinition column,
    SchemaChange change,
  ) {
    final ref = column.relationship?.references;
    final targetTable = _toSnake(ref ?? column.name);
    final fkName = '${model.tableName}_${column.name}_fkey';
    final fkCol = '${column.name}_id';
    final upSql = 'ALTER TABLE ${_quoteIdent(model.tableName)} '
        'ADD CONSTRAINT ${_quoteIdent(fkName)} '
        'FOREIGN KEY (${_quoteIdent(fkCol)}) REFERENCES ${_quoteIdent(targetTable)} (${_quoteIdent('id')}) '
        'ON DELETE SET NULL ON UPDATE CASCADE;';
    final downSql =
        'ALTER TABLE ${_quoteIdent(model.tableName)} DROP CONSTRAINT IF EXISTS ${_quoteIdent(fkName)};';
    return MigrationOperation(upSql: upSql, downSql: downSql, change: change);
  }

  MigrationOperation _generateDropForeignKeyOperation(
    ModelDefinition model,
    ColumnDefinition column,
    SchemaChange change,
  ) {
    final ref = column.relationship?.references;
    final targetTable = _toSnake(ref ?? column.name);
    final fkName = '${model.tableName}_${column.name}_fkey';
    final fkCol = '${column.name}_id';
    final upSql =
        'ALTER TABLE ${_quoteIdent(model.tableName)} DROP CONSTRAINT IF EXISTS ${_quoteIdent(fkName)};';
    final downSql = 'ALTER TABLE ${_quoteIdent(model.tableName)} '
        'ADD CONSTRAINT ${_quoteIdent(fkName)} '
        'FOREIGN KEY (${_quoteIdent(fkCol)}) REFERENCES ${_quoteIdent(targetTable)} (${_quoteIdent('id')}) '
        'ON DELETE SET NULL ON UPDATE CASCADE;';
    return MigrationOperation(upSql: upSql, downSql: downSql, change: change);
  }

  String _toSnake(String s) => s
      .replaceAllMapped(
          RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}')
      .replaceFirst(RegExp(r'^_'), '');

  MigrationOperation _generateAddIndexOperation(
      ModelDefinition model, IndexDefinition index, SchemaChange change) {
    final upSql = _createIndexSql(model, index);
    final downSql = 'DROP INDEX IF EXISTS ${_quoteIdent(index.name)};';

    return MigrationOperation(
      upSql: upSql,
      downSql: downSql,
      change: change,
    );
  }

  MigrationOperation _generateDropIndexOperation(
      ModelDefinition model, IndexDefinition index, SchemaChange change) {
    final upSql = 'DROP INDEX IF EXISTS ${_quoteIdent(index.name)};';
    final downSql = _createIndexSql(model, index);

    return MigrationOperation(
      upSql: upSql,
      downSql: downSql,
      change: change,
    );
  }

  String _createIndexSql(ModelDefinition model, IndexDefinition index) {
    if (index.using != null) {
      if (index.columns.length != 1) {
        // pgvector indexes are single-column; fall through to the
        // default form so we don't produce invalid SQL.
        return _createBtreeIndexSql(model, index);
      }
      final colName = index.columns.single;
      final ownerCol =
          model.columns.where((c) => c.name == colName).firstOrNull;
      final distance =
          index.distance ?? ownerCol?.vector?.distance ?? VectorDistance.l2;
      return 'CREATE INDEX ${_quoteIdent(index.name)} '
          'ON ${_quoteIdent(model.tableName)} '
          'USING ${index.using!.name} '
          '(${_quoteIdent(colName)} ${distance.opclass});';
    }
    return _createBtreeIndexSql(model, index);
  }

  String _createBtreeIndexSql(ModelDefinition model, IndexDefinition index) {
    final uniqueStr = index.isUnique ? 'UNIQUE ' : '';
    final columnsStr = index.columns.map(_quoteIdent).join(', ');
    return 'CREATE ${uniqueStr}INDEX ${_quoteIdent(index.name)} '
        'ON ${_quoteIdent(model.tableName)} ($columnsStr);';
  }

  /// Generate complete CREATE TABLE SQL
  String _generateCreateTableSql(ModelDefinition model) {
    final buffer = StringBuffer();
    buffer.writeln('CREATE TABLE ${_quoteIdent(model.tableName)} (');

    final columnDefs = <String>[];
    for (final column in model.columns) {
      if (!column.isRelationship || column.type == ColumnType.foreignKey) {
        columnDefs.add('  ${_generateColumnDefinition(column)}');
      }
    }

    buffer.writeln(columnDefs.join(',\n'));
    buffer.write(');');

    return buffer.toString();
  }

  /// Generate column definition SQL
  String _generateColumnDefinition(ColumnDefinition column) {
    final buffer = StringBuffer();

    if (column.type == ColumnType.foreignKey) {
      buffer
          .write('${_quoteIdent('${column.name}_id')} ${column.postgresType}');
    } else {
      buffer.write('${_quoteIdent(column.name)} ${column.postgresType}');
    }

    if (column.constraints.isPrimary) {
      buffer.write(' PRIMARY KEY');
    }

    if (!column.constraints.isNull) {
      buffer.write(' NOT NULL');
    }

    if (column.constraints.isUnique && !column.constraints.isPrimary) {
      buffer.write(' UNIQUE');
    }

    if (column.constraints.defaultValue != null) {
      buffer.write(' DEFAULT ${column.constraints.defaultValue}');
    }

    return buffer.toString();
  }

  /// Generate migration file from diff
  Future<void> generateMigrationFile(
      SchemaDiff diff, String outputPath, String migrationName) async {
    if (diff.isEmpty) {
      throw ArgumentError('No changes to generate migration for');
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final upFile = File('$outputPath/${timestamp}_$migrationName.up.sql');
    final downFile = File('$outputPath/${timestamp}_$migrationName.down.sql');

    // Create output directory
    await Directory(outputPath).create(recursive: true);

    // Generate up migration
    final upBuffer = StringBuffer();
    upBuffer.writeln('-- Migration: $migrationName');
    upBuffer.writeln('-- Generated on: ${DateTime.now().toIso8601String()}');
    upBuffer.writeln();
    upBuffer.writeln('BEGIN;');
    upBuffer.writeln();

    for (final operation in diff.operations) {
      upBuffer.writeln('-- ${operation.change}');
      upBuffer.writeln(operation.upSql);
      upBuffer.writeln();
    }

    upBuffer.writeln('COMMIT;');

    // Generate down migration
    final downBuffer = StringBuffer();
    downBuffer.writeln('-- Down migration: $migrationName');
    downBuffer.writeln('-- Generated on: ${DateTime.now().toIso8601String()}');
    downBuffer.writeln();
    downBuffer.writeln('BEGIN;');
    downBuffer.writeln();

    // Reverse order for down migration
    for (final operation in diff.operations.reversed) {
      downBuffer.writeln('-- Rollback: ${operation.change}');
      downBuffer.writeln(operation.downSql);
      downBuffer.writeln();
    }

    downBuffer.writeln('COMMIT;');

    // Write files
    await upFile.writeAsString(upBuffer.toString());
    await downFile.writeAsString(downBuffer.toString());

    print('Generated migration files:');
    print('   Up:   ${upFile.path}');
    print('   Down: ${downFile.path}');
  }
}

/// Internal pairing used while detecting renames.
class _RenamePair {
  final String oldName;
  final String newName;
  const _RenamePair({required this.oldName, required this.newName});
}

/// SQL pair used internally to emit/reverse the implicit pgvector
/// index associated with a column that has `is_index: true`.
class _ImplicitIndex {
  final String upSql;
  final String downSql;
  const _ImplicitIndex({required this.upSql, required this.downSql});
}
