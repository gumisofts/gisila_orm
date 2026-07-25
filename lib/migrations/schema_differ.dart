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
import 'package:gisila_orm/database/types.dart';
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
  addEnum,
  dropEnum,
  addEnumValue,
  addCheck,
  dropCheck,
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
      case ChangeType.addEnum:
        return 'Create enum: $newName';
      case ChangeType.dropEnum:
        return 'Drop enum: $oldName';
      case ChangeType.addEnumValue:
        return 'Add enum value: $oldName + $newName';
      case ChangeType.addCheck:
        return 'Add check: $tableName.$columnName';
      case ChangeType.dropCheck:
        return 'Drop check: $tableName.$columnName';
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
  // Populated at the start of each `compareSchemas` call so the
  // migration-operation generators below can resolve what a relationship
  // column's `_id` type/target-column should actually be, instead of
  // hardcoding `INTEGER ... REFERENCES ... ("id")`. Keyed by model name.
  Map<String, ModelDefinition> _oldModelsByName = const {};
  Map<String, ModelDefinition> _newModelsByName = const {};

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

    _oldModelsByName = oldModels;
    _newModelsByName = newModels;

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

    // Enum types (CREATE TYPE / ADD VALUE). Destructive enum drops are
    // emitted after tables that may depend on them are handled.
    _compareEnums(oldSchema, newSchema, changes, operations);

    // Find table changes
    _compareModels(oldModels, newModels, changes, operations);

    // Check for destructive changes
    final hasDestructive = changes.any((change) =>
        change.type == ChangeType.dropTable ||
        change.type == ChangeType.dropColumn ||
        change.type == ChangeType.modifyColumn ||
        change.type == ChangeType.dropEnum ||
        change.type == ChangeType.dropCheck);

    return SchemaDiff(
      changes: changes,
      operations: operations,
      hasDestructiveChanges: hasDestructive,
    );
  }

  void _compareEnums(
    SchemaDefinition oldSchema,
    SchemaDefinition newSchema,
    List<SchemaChange> changes,
    List<MigrationOperation> operations,
  ) {
    final oldEnums = {for (final e in oldSchema.enums) e.name: e};
    final newEnums = {for (final e in newSchema.enums) e.name: e};

    for (final e in newEnums.values) {
      final old = oldEnums[e.name];
      if (old == null) {
        final change = SchemaChange(
          type: ChangeType.addEnum,
          newName: e.name,
        );
        changes.add(change);
        final values = e.values.map((v) => "'$v'").join(', ');
        operations.add(MigrationOperation(
          upSql:
              'CREATE TYPE ${_quoteIdent(e.postgresTypeName)} AS ENUM ($values);',
          downSql: 'DROP TYPE IF EXISTS ${_quoteIdent(e.postgresTypeName)};',
          change: change,
        ));
        continue;
      }
      // Additive values only. Removals/renames require manual SQL.
      for (final v in e.values) {
        if (old.values.contains(v)) continue;
        final change = SchemaChange(
          type: ChangeType.addEnumValue,
          oldName: e.name,
          newName: v,
        );
        changes.add(change);
        operations.add(MigrationOperation(
          // ADD VALUE cannot run inside a transaction block on older
          // Postgres; document that authors may need to apply outside BEGIN.
          upSql:
              'ALTER TYPE ${_quoteIdent(e.postgresTypeName)} ADD VALUE IF NOT EXISTS \'$v\';',
          downSql:
              '-- Cannot automatically remove enum value "$v" from ${e.postgresTypeName}',
          change: change,
        ));
      }
    }

    for (final e in oldEnums.values) {
      if (newEnums.containsKey(e.name)) continue;
      final change = SchemaChange(
        type: ChangeType.dropEnum,
        oldName: e.name,
      );
      changes.add(change);
      operations.add(MigrationOperation(
        upSql: 'DROP TYPE IF EXISTS ${_quoteIdent(e.postgresTypeName)};',
        downSql: () {
          final values = e.values.map((v) => "'$v'").join(', ');
          return 'CREATE TYPE ${_quoteIdent(e.postgresTypeName)} AS ENUM ($values);';
        }(),
        change: change,
      ));
    }
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

        // Compare named CHECK constraints
        _compareChecks(oldModel, newModel, changes, operations);
      }
    }
  }

  void _compareChecks(
    ModelDefinition oldModel,
    ModelDefinition newModel,
    List<SchemaChange> changes,
    List<MigrationOperation> operations,
  ) {
    final oldChecks = {
      for (final c in oldModel.allChecks) c.name: c,
    };
    final newChecks = {
      for (final c in newModel.allChecks) c.name: c,
    };

    for (final name in oldChecks.keys) {
      if (newChecks.containsKey(name) &&
          oldChecks[name]!.expression == newChecks[name]!.expression) {
        continue;
      }
      if (!newChecks.containsKey(name) ||
          oldChecks[name]!.expression != newChecks[name]!.expression) {
        final change = SchemaChange(
          type: ChangeType.dropCheck,
          tableName: newModel.tableName,
          columnName: name,
        );
        changes.add(change);
        final old = oldChecks[name]!;
        operations.add(MigrationOperation(
          upSql:
              'ALTER TABLE ${_quoteIdent(newModel.tableName)} DROP CONSTRAINT IF EXISTS ${_quoteIdent(name)};',
          downSql:
              'ALTER TABLE ${_quoteIdent(newModel.tableName)} ADD CONSTRAINT ${_quoteIdent(name)} CHECK (${old.expression});',
          change: change,
        ));
      }
    }

    for (final name in newChecks.keys) {
      final neu = newChecks[name]!;
      final old = oldChecks[name];
      if (old != null && old.expression == neu.expression) continue;
      final change = SchemaChange(
        type: ChangeType.addCheck,
        tableName: newModel.tableName,
        columnName: name,
      );
      changes.add(change);
      operations.add(MigrationOperation(
        upSql:
            'ALTER TABLE ${_quoteIdent(newModel.tableName)} ADD CONSTRAINT ${_quoteIdent(name)} CHECK (${neu.expression});',
        downSql:
            'ALTER TABLE ${_quoteIdent(newModel.tableName)} DROP CONSTRAINT IF EXISTS ${_quoteIdent(name)};',
        change: change,
      ));
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

    // 5. In-place modifications / FK promotions for columns that keep
    //    the same logical YAML name.
    for (final newCol in newColumns.values) {
      final oldCol = oldColumns[newCol.name];
      if (oldCol == null) continue;

      // Physical rename when a scalar becomes an FK (or the reverse):
      // e.g. `merchant` (uuid) → `merchant` (FK) stores as `merchant_id`.
      if (oldCol.physicalColumnName != newCol.physicalColumnName) {
        final rename = _RenamePair(
          oldName: oldCol.physicalColumnName,
          newName: newCol.physicalColumnName,
        );
        final change = SchemaChange(
          type: ChangeType.renameColumn,
          tableName: newModel.tableName,
          oldName: rename.oldName,
          newName: rename.newName,
        );
        changes.add(change);
        operations.add(_generateRenameColumnOperation(newModel, rename, change));
      }

      final oldIsFk = oldCol.type == ColumnType.foreignKey;
      final newIsFk = newCol.type == ColumnType.foreignKey;
      if (!oldIsFk && newIsFk) {
        final fkChange = SchemaChange(
          type: ChangeType.addForeignKey,
          tableName: newModel.tableName,
          columnName: newCol.name,
        );
        changes.add(fkChange);
        operations
            .add(_generateAddForeignKeyOperation(newModel, newCol, fkChange));
      } else if (oldIsFk && !newIsFk) {
        final fkChange = SchemaChange(
          type: ChangeType.dropForeignKey,
          tableName: newModel.tableName,
          columnName: oldCol.name,
        );
        changes.add(fkChange);
        operations
            .add(_generateDropForeignKeyOperation(newModel, oldCol, fkChange));
      } else if (oldIsFk && newIsFk && _foreignKeyConstraintChanged(oldCol, newCol)) {
        // Recreate the constraint when the target / referential actions
        // change. Physical type changes are handled below.
        final dropChange = SchemaChange(
          type: ChangeType.dropForeignKey,
          tableName: newModel.tableName,
          columnName: oldCol.name,
        );
        changes.add(dropChange);
        operations
            .add(_generateDropForeignKeyOperation(newModel, oldCol, dropChange));
        final addChange = SchemaChange(
          type: ChangeType.addForeignKey,
          tableName: newModel.tableName,
          columnName: newCol.name,
        );
        changes.add(addChange);
        operations
            .add(_generateAddForeignKeyOperation(newModel, newCol, addChange));
      }

      if (_isColumnModified(oldCol, newCol)) {
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
  /// "compatible" for a rename when they share the same *resolved*
  /// Postgres type signature and nullability/uniqueness profile.
  ///
  /// Foreign-key columns resolve to their referenced PK type, so a bare
  /// `uuid` column can rename into a `foreign_key` that points at a UUID
  /// primary key (and vice versa) without being treated as drop+add.
  bool _columnsLookCompatible(ColumnDefinition a, ColumnDefinition b) {
    if (_resolvedPostgresType(a, useOld: true) !=
        _resolvedPostgresType(b, useOld: false)) {
      return false;
    }
    if (a.constraints.isNull != b.constraints.isNull) return false;
    if (a.constraints.isPrimary != b.constraints.isPrimary) return false;
    return true;
  }

  /// Postgres type that will actually be emitted for [column].
  ///
  /// Foreign keys inherit the referenced model's primary-key type
  /// (`UUID`, `BIGINT`, …). Falling back to [ColumnDefinition.postgresType]
  /// for FKs would incorrectly report `INTEGER` and cause diffs like
  /// `ALTER COLUMN … TYPE INTEGER` when promoting a UUID column to an FK.
  String _resolvedPostgresType(ColumnDefinition column,
      {required bool useOld}) {
    if (column.type == ColumnType.foreignKey) {
      final models = useOld ? _oldModelsByName : _newModelsByName;
      final refPk = models[column.relationship?.references]?.primaryKey;
      return refPk?.effectivePostgresType ?? 'BIGINT';
    }
    return column.effectivePostgresType;
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

  /// Whether [oldCol]/[newCol] need an in-place attribute migration
  /// (`ALTER COLUMN … TYPE/NULL/DEFAULT`).
  ///
  /// A bare type flip of `uuid` → `foreign_key` (or the reverse) is **not**
  /// a column modification when the resolved Postgres type is unchanged —
  /// the FK constraint transition is emitted separately. Comparing
  /// [ColumnDefinition.postgresType] directly is wrong for FKs because
  /// that getter hardcodes `INTEGER`.
  bool _isColumnModified(ColumnDefinition oldCol, ColumnDefinition newCol) {
    final oldType = _resolvedPostgresType(oldCol, useOld: true);
    final newType = _resolvedPostgresType(newCol, useOld: false);
    if (oldType != newType) return true;
    if (oldCol.constraints.isNull != newCol.constraints.isNull) return true;
    if (oldCol.constraints.isUnique != newCol.constraints.isUnique) return true;
    if (oldCol.constraints.isPrimary != newCol.constraints.isPrimary) {
      return true;
    }
    if (oldCol.constraints.defaultValue != newCol.constraints.defaultValue) {
      return true;
    }
    if (oldCol.constraints.maxLength != newCol.constraints.maxLength) {
      return true;
    }
    // Vector-specific shape changes also need a migration: the
    // declared type carries the dimensions (`VECTOR(n)`), so we have
    // to detect changes to `dimensions`, and an index method or
    // distance flip means dropping/re-creating the index.
    if (oldCol.type == ColumnType.vector && newCol.type == ColumnType.vector) {
      final ov = oldCol.vector;
      final nv = newCol.vector;
      if (ov?.indexMethod != nv?.indexMethod) return true;
      if (ov?.distance != nv?.distance) return true;
      if (oldCol.constraints.isIndex != newCol.constraints.isIndex) return true;
    }
    if (oldCol.type == ColumnType.array && newCol.type == ColumnType.array) {
      if (oldCol.array?.elementType != newCol.array?.elementType) return true;
      if (oldCol.array?.maxLength != newCol.array?.maxLength) return true;
    }
    if (oldCol.type == ColumnType.enumType &&
        newCol.type == ColumnType.enumType) {
      if (oldCol.enumConfig?.enumName != newCol.enumConfig?.enumName) {
        return true;
      }
    }
    return false;
  }

  bool _foreignKeyConstraintChanged(
    ColumnDefinition oldCol,
    ColumnDefinition newCol,
  ) {
    final oldRel = oldCol.relationship;
    final newRel = newCol.relationship;
    if (oldRel?.references != newRel?.references) return true;
    if ((oldRel?.onDelete ?? 'SET NULL') != (newRel?.onDelete ?? 'SET NULL')) {
      return true;
    }
    if ((oldRel?.onUpdate ?? 'CASCADE') != (newRel?.onUpdate ?? 'CASCADE')) {
      return true;
    }
    return false;
  }

  // Migration operation generators

  MigrationOperation _generateCreateTableOperation(
      ModelDefinition model, SchemaChange change) {
    final buf = StringBuffer(_generateCreateTableSql(model));
    for (final check in model.checks) {
      buf.write(
        '\nALTER TABLE ${_quoteIdent(model.tableName)} '
        'ADD CONSTRAINT ${_quoteIdent(check.name)} CHECK (${check.expression});',
      );
    }
    final upSql = buf.toString();
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
    final downSql = _generateCreateTableSql(model, useOld: true);

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
    // The dropped column belonged to the old schema, so any FK target
    // it pointed at must be resolved there too (the new schema may no
    // longer have that model, or may have changed its primary key).
    final columnDef = _generateColumnDefinition(column, useOld: true);
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

    final oldType = _resolvedPostgresType(oldColumn, useOld: true);
    final newType = _resolvedPostgresType(newColumn, useOld: false);
    // Physical renames (if any) are emitted before this op on the way up,
    // and reversed after this op on the way down — so both directions
    // must target the *new* physical column name.
    final colIdent = _quoteIdent(newColumn.physicalColumnName);
    final upCol = colIdent;
    final downCol = colIdent;
    if (oldType != newType) {
      upStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $upCol '
        'TYPE $newType;',
      );
      downStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $downCol '
        'TYPE $oldType;',
      );
    }
    if (oldColumn.constraints.isNull != newColumn.constraints.isNull) {
      final upClause =
          newColumn.constraints.isNull ? 'DROP NOT NULL' : 'SET NOT NULL';
      final downClause =
          oldColumn.constraints.isNull ? 'DROP NOT NULL' : 'SET NOT NULL';
      upStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $upCol $upClause;',
      );
      downStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $downCol $downClause;',
      );
    }
    if (oldColumn.constraints.defaultValue !=
        newColumn.constraints.defaultValue) {
      if (newColumn.constraints.defaultValue == null) {
        upStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $upCol DROP DEFAULT;',
        );
      } else {
        upStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $upCol '
          'SET DEFAULT ${_formatDefault(newColumn)};',
        );
      }
      if (oldColumn.constraints.defaultValue == null) {
        downStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $downCol DROP DEFAULT;',
        );
      } else {
        downStmts.add(
          'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $downCol '
          'SET DEFAULT ${_formatDefault(oldColumn)};',
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
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $upCol '
        'TYPE $newType;',
      );
      downStmts.add(
        'ALTER TABLE ${_quoteIdent(model.tableName)} ALTER COLUMN $downCol '
        'TYPE $oldType;',
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
    final target = _newModelsByName[ref];
    final targetTable = target?.tableName ?? _toSnake(ref ?? column.name);
    final targetPkName = target?.primaryKey?.name ?? 'id';
    final fkName = '${model.tableName}_${column.name}_fkey';
    final fkCol = column.physicalColumnName;
    final onDelete = column.relationship?.onDelete ?? 'SET NULL';
    final onUpdate = column.relationship?.onUpdate ?? 'CASCADE';
    final upSql = 'ALTER TABLE ${_quoteIdent(model.tableName)} '
        'ADD CONSTRAINT ${_quoteIdent(fkName)} '
        'FOREIGN KEY (${_quoteIdent(fkCol)}) REFERENCES ${_quoteIdent(targetTable)} (${_quoteIdent(targetPkName)}) '
        'ON DELETE $onDelete ON UPDATE $onUpdate;';
    final downSql =
        'ALTER TABLE ${_quoteIdent(model.tableName)} DROP CONSTRAINT IF EXISTS ${_quoteIdent(fkName)};';
    return MigrationOperation(upSql: upSql, downSql: downSql, change: change);
  }

  MigrationOperation _generateDropForeignKeyOperation(
    ModelDefinition model,
    ColumnDefinition column,
    SchemaChange change,
  ) {
    // This FK belonged to the old schema; resolve its target there too.
    final ref = column.relationship?.references;
    final target = _oldModelsByName[ref];
    final targetTable = target?.tableName ?? _toSnake(ref ?? column.name);
    final targetPkName = target?.primaryKey?.name ?? 'id';
    final fkName = '${model.tableName}_${column.name}_fkey';
    final fkCol = column.physicalColumnName;
    final onDelete = column.relationship?.onDelete ?? 'SET NULL';
    final onUpdate = column.relationship?.onUpdate ?? 'CASCADE';
    final upSql =
        'ALTER TABLE ${_quoteIdent(model.tableName)} DROP CONSTRAINT IF EXISTS ${_quoteIdent(fkName)};';
    final downSql = 'ALTER TABLE ${_quoteIdent(model.tableName)} '
        'ADD CONSTRAINT ${_quoteIdent(fkName)} '
        'FOREIGN KEY (${_quoteIdent(fkCol)}) REFERENCES ${_quoteIdent(targetTable)} (${_quoteIdent(targetPkName)}) '
        'ON DELETE $onDelete ON UPDATE $onUpdate;';
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
      final logicalName = index.columns.single;
      final colName = _physicalIndexColumn(logicalName, model);
      final ownerCol =
          model.columns.where((c) => c.name == logicalName).firstOrNull;
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
    final columnsStr = index.columns
        .map((c) => _quoteIdent(_physicalIndexColumn(c, model)))
        .join(', ');
    return 'CREATE ${uniqueStr}INDEX ${_quoteIdent(index.name)} '
        'ON ${_quoteIdent(model.tableName)} ($columnsStr);';
  }

  String _physicalIndexColumn(String logicalName, ModelDefinition model) {
    final col = model.columns.where((c) => c.name == logicalName).firstOrNull;
    return col?.physicalColumnName ?? logicalName;
  }

  String _formatDefault(ColumnDefinition column) {
    final value = column.constraints.defaultValue;
    if (column.type == ColumnType.enumType) {
      final lit = value.toString().replaceAll("'", "''");
      return "'$lit'::${column.enumConfig!.postgresTypeName}";
    }
    if (column.type == ColumnType.array) {
      return DefaultEngine.instance.formatArrayDefault(
        value,
        column.array!.pgCast,
        columnLabel: column.name,
      );
    }
    if (column.type == ColumnType.point ||
        column.type == ColumnType.box ||
        column.type == ColumnType.circle ||
        column.type == ColumnType.lseg) {
      final lit = value.toString().replaceAll("'", "''");
      return "'$lit'::${column.type.name}";
    }
    return DefaultEngine.instance.formatForSql(
      value,
      column.dartType.replaceAll('?', ''),
      columnLabel: column.name,
    );
  }

  /// Generate complete CREATE TABLE SQL. [useOld] is forwarded to
  /// [_generateColumnDefinition] - pass `true` when [model] comes from
  /// the old schema (e.g. recreating a dropped table on rollback).
  String _generateCreateTableSql(ModelDefinition model, {bool useOld = false}) {
    final buffer = StringBuffer();
    buffer.writeln('CREATE TABLE ${_quoteIdent(model.tableName)} (');

    final columnDefs = <String>[];
    for (final column in model.columns) {
      if (!column.isRelationship || column.type == ColumnType.foreignKey) {
        columnDefs
            .add('  ${_generateColumnDefinition(column, useOld: useOld)}');
      }
    }
    for (final col in model.columns) {
      final expr = col.checkExpression;
      if (expr == null || expr.isEmpty) continue;
      final name = '${model.tableName}_${col.name}_check';
      columnDefs.add('  CONSTRAINT ${_quoteIdent(name)} CHECK ($expr)');
    }

    buffer.writeln(columnDefs.join(',\n'));
    buffer.write(');');

    return buffer.toString();
  }

  /// Generate column definition SQL. [useOld] picks which schema
  /// snapshot to resolve a foreign key's target primary key against -
  /// `true` for columns being dropped/rolled-back (they referenced the
  /// old schema), `false` (default) for columns being added.
  String _generateColumnDefinition(ColumnDefinition column,
      {bool useOld = false}) {
    final buffer = StringBuffer();

    if (column.type == ColumnType.foreignKey) {
      final models = useOld ? _oldModelsByName : _newModelsByName;
      final refPk = models[column.relationship?.references]?.primaryKey;
      final refType = refPk?.effectivePostgresType ?? 'BIGINT';
      buffer.write('${_quoteIdent(column.physicalColumnName)} $refType');
    } else if (column.constraints.isPrimary &&
        (column.type == ColumnType.integer ||
            column.type == ColumnType.bigint)) {
      // Match sql_emitter: an implicit/explicit INTEGER/BIGINT primary
      // key is always auto-incrementing.
      buffer.write('${_quoteIdent(column.name)} BIGSERIAL');
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
      buffer.write(' DEFAULT ${_formatDefault(column)}');
    }

    return buffer.toString();
  }

  // Note: column-level CHECK expression changes are handled via
  // `_compareChecks` using synthesized constraint names.

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
