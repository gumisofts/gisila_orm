/// Schema parser & validator for Gisila ORM.
///
/// Loads a `*.gisila.yaml` document with full source-span tracking
/// and produces a [SchemaDefinition]. Every shape mistake the user
/// can make in the YAML is reported as a [SchemaError] tied to the
/// exact line/column of the offending token; the parser collects
/// them all and then throws a single [SchemaValidationException].
library gisila.generators.schema_parser;

import 'dart:io';

import 'package:gisila_orm/database/postgres/types/vector.dart';
import 'package:gisila_orm/generators/schema_errors.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

export 'package:gisila_orm/generators/schema_errors.dart'
    show SchemaError, SchemaErrorLevel, SchemaValidationException;

/// Supported column data types
enum ColumnType {
  varchar,
  text,
  integer,
  bigint,
  boolean,
  date,
  timestamp,
  decimal,
  json,
  uuid,

  /// pgvector `vector(n)` column. Requires the `vector` extension.
  vector,

  /// Postgres array of a scalar builtin (`varchar[]`, `integer[]`, …).
  array,

  /// Schema-declared Postgres ENUM (`enums:` block + `type: EnumName`).
  enumType,

  /// Geometric types.
  point,
  box,
  circle,
  lseg,

  // Reference types
  foreignKey,
  manyToMany,
}

/// Top-level Postgres ENUM declaration from the schema `enums:` block.
class EnumDefinition {
  final String name;
  final List<String> values;

  const EnumDefinition({required this.name, required this.values});

  /// Snake_case Postgres type name (`TeamRole` → `team_role`).
  String get postgresTypeName => _toSnakeCase(name);
}

/// Array element configuration for [ColumnType.array] columns.
class ArrayConfig {
  final ColumnType elementType;

  /// For `varchar[]`, optional max length of the element type.
  final int? maxLength;

  const ArrayConfig({required this.elementType, this.maxLength});

  String get elementPostgresType {
    switch (elementType) {
      case ColumnType.varchar:
        return 'VARCHAR(${maxLength ?? 255})';
      case ColumnType.text:
        return 'TEXT';
      case ColumnType.integer:
        return 'INTEGER';
      case ColumnType.bigint:
        return 'BIGINT';
      case ColumnType.boolean:
        return 'BOOLEAN';
      case ColumnType.date:
        return 'DATE';
      case ColumnType.timestamp:
        return 'TIMESTAMP WITH TIME ZONE';
      case ColumnType.decimal:
        return 'DECIMAL';
      case ColumnType.uuid:
        return 'UUID';
      default:
        return elementType.name.toUpperCase();
    }
  }

  String get elementDartType {
    switch (elementType) {
      case ColumnType.varchar:
      case ColumnType.text:
      case ColumnType.uuid:
        return 'String';
      case ColumnType.integer:
      case ColumnType.bigint:
        return 'int';
      case ColumnType.boolean:
        return 'bool';
      case ColumnType.date:
      case ColumnType.timestamp:
        return 'DateTime';
      case ColumnType.decimal:
        return 'double';
      default:
        return 'Object';
    }
  }

  /// Postgres cast suffix for bound parameters, e.g. `varchar[]`.
  String get pgCast {
    switch (elementType) {
      case ColumnType.varchar:
        return 'varchar[]';
      case ColumnType.text:
        return 'text[]';
      case ColumnType.integer:
        return 'integer[]';
      case ColumnType.bigint:
        return 'bigint[]';
      case ColumnType.boolean:
        return 'boolean[]';
      case ColumnType.date:
        return 'date[]';
      case ColumnType.timestamp:
        return 'timestamptz[]';
      case ColumnType.decimal:
        return 'numeric[]';
      case ColumnType.uuid:
        return 'uuid[]';
      default:
        return 'text[]';
    }
  }
}

/// Named CHECK constraint (column- or table-level).
class CheckConstraint {
  final String name;
  final String expression;

  /// When set, this check was declared on a single column.
  final String? columnName;

  const CheckConstraint({
    required this.name,
    required this.expression,
    this.columnName,
  });
}

/// Enum-typed column metadata.
class EnumConfig {
  final String enumName;
  final List<String> values;

  const EnumConfig({required this.enumName, required this.values});

  String get postgresTypeName => _toSnakeCase(enumName);
}

/// Column constraint configuration
class ColumnConstraints {
  final bool isNull;
  final bool isUnique;
  final bool isIndex;
  final bool isPrimary;
  final bool allowBlank;
  final dynamic defaultValue;

  /// Optional max length for `varchar` columns. When set, emits
  /// `VARCHAR(n)` instead of the default `VARCHAR(255)`.
  final int? maxLength;

  const ColumnConstraints({
    this.isNull = true,
    this.isUnique = false,
    this.isIndex = false,
    this.isPrimary = false,
    this.allowBlank = true,
    this.defaultValue,
    this.maxLength,
  });
}

/// Relationship configuration
class RelationshipConfig {
  final String? references;
  final String? reverseName;
  final bool isManyToMany;
  final String? onDelete;
  final String? onUpdate;

  const RelationshipConfig({
    this.references,
    this.reverseName,
    this.isManyToMany = false,
    this.onDelete,
    this.onUpdate,
  });
}

/// Vector-specific configuration carried alongside a [ColumnDefinition]
/// when [ColumnDefinition.type] is [ColumnType.vector].
///
/// `dimensions` is required; `indexMethod` and `distance` are only
/// consulted when [ColumnConstraints.isIndex] is true (or when an
/// explicit index in the `indexes:` block targets this column).
class VectorConfig {
  /// Number of dimensions; required and must be positive.
  final int dimensions;

  /// Vector index method to use when an implicit index is requested
  /// for this column. Defaults to HNSW.
  final VectorIndexMethod indexMethod;

  /// Distance metric used by the implicit index and any inferred
  /// opclass. Defaults to [VectorDistance.l2].
  final VectorDistance distance;

  const VectorConfig({
    required this.dimensions,
    this.indexMethod = VectorIndexMethod.hnsw,
    this.distance = VectorDistance.l2,
  });
}

/// Column definition
class ColumnDefinition {
  final String name;
  final ColumnType type;
  final ColumnConstraints constraints;
  final RelationshipConfig? relationship;
  final VectorConfig? vector;
  final ArrayConfig? array;
  final EnumConfig? enumConfig;

  /// Column-level CHECK expression (unnamed until emitter assigns a name).
  final String? checkExpression;

  const ColumnDefinition({
    required this.name,
    required this.type,
    required this.constraints,
    this.relationship,
    this.vector,
    this.array,
    this.enumConfig,
    this.checkExpression,
  });

  /// Get Dart type representation
  String get dartType {
    final baseType = _getDartBaseType();
    final nullable = constraints.isNull && !constraints.isPrimary ? '?' : '';
    return '$baseType$nullable';
  }

  String _getDartBaseType() {
    switch (type) {
      case ColumnType.varchar:
      case ColumnType.text:
      case ColumnType.uuid:
        return 'String';
      case ColumnType.integer:
      case ColumnType.bigint:
        return 'int';
      case ColumnType.boolean:
        return 'bool';
      case ColumnType.date:
      case ColumnType.timestamp:
        return 'DateTime';
      case ColumnType.decimal:
        return 'double';
      case ColumnType.json:
        return 'Map<String, dynamic>';
      case ColumnType.vector:
        return 'Vector';
      case ColumnType.array:
        return 'List<${array?.elementDartType ?? 'Object'}>';
      case ColumnType.enumType:
        return enumConfig?.enumName ?? 'Object';
      case ColumnType.point:
        return 'Point';
      case ColumnType.box:
        return 'Box';
      case ColumnType.circle:
        return 'Circle';
      case ColumnType.lseg:
        return 'Lseg';
      case ColumnType.foreignKey:
        return relationship?.references ?? 'Object';
      case ColumnType.manyToMany:
        return 'List<${relationship?.references ?? 'Object'}>';
    }
  }

  /// Get PostgreSQL type representation
  String get postgresType {
    switch (type) {
      case ColumnType.varchar:
        final n = constraints.maxLength ?? 255;
        return 'VARCHAR($n)';
      case ColumnType.text:
        return 'TEXT';
      case ColumnType.integer:
        return 'INTEGER';
      case ColumnType.bigint:
        return 'BIGINT';
      case ColumnType.boolean:
        return 'BOOLEAN';
      case ColumnType.date:
        return 'DATE';
      case ColumnType.timestamp:
        return 'TIMESTAMP WITH TIME ZONE';
      case ColumnType.decimal:
        return 'DECIMAL';
      case ColumnType.json:
        return 'JSONB';
      case ColumnType.uuid:
        return 'UUID';
      case ColumnType.vector:
        final dim = vector?.dimensions;
        return dim == null ? 'VECTOR' : 'VECTOR($dim)';
      case ColumnType.array:
        return '${array?.elementPostgresType ?? 'TEXT'}[]';
      case ColumnType.enumType:
        return '"${enumConfig?.postgresTypeName ?? name}"';
      case ColumnType.point:
        return 'POINT';
      case ColumnType.box:
        return 'BOX';
      case ColumnType.circle:
        return 'CIRCLE';
      case ColumnType.lseg:
        return 'LSEG';
      case ColumnType.foreignKey:
        return 'INTEGER';
      case ColumnType.manyToMany:
        return ''; // Handled by junction table
    }
  }

  bool get isRelationship =>
      type == ColumnType.foreignKey || type == ColumnType.manyToMany;

  /// Physical database column name.
  ///
  /// Foreign keys are stored as `<name>_id` unless [name] already ends
  /// with `_id` (so a YAML field `user_id` maps to `"user_id"`, not
  /// `"user_id_id"`). Non-FK columns use [name] as-is.
  String get physicalColumnName {
    if (type == ColumnType.foreignKey) {
      return physicalForeignKeyColumnName(name);
    }
    return name;
  }

  /// Dart field name for this column on the generated model class.
  ///
  /// Foreign-key fields use the camelCase of [physicalColumnName]
  /// (e.g. `author` → `authorId`, `user_id` → `userId`).
  String get dartFieldName {
    if (type == ColumnType.foreignKey) {
      return _camelCaseIdent(physicalColumnName);
    }
    return _camelCaseIdent(name);
  }

  /// The type Postgres actually gives this column once DDL runs.
  ///
  /// [postgresType] is purely nominal - an INTEGER/BIGINT column with
  /// `is_primary: true` is emitted as `BIGSERIAL PRIMARY KEY` (see the
  /// SQL emitter), and `BIGSERIAL` is sugar for a `bigint` column plus a
  /// sequence-backed default, not a distinct type. Anything that needs
  /// to match this column's *real* type (foreign keys, junction tables)
  /// must use this getter instead of [postgresType].
  String get effectivePostgresType {
    if (constraints.isPrimary &&
        (type == ColumnType.integer || type == ColumnType.bigint)) {
      return 'BIGINT';
    }
    return postgresType;
  }
}

/// Index definition
class IndexDefinition {
  final String name;
  final List<String> columns;
  final bool isUnique;

  /// pgvector index method (`hnsw`/`ivfflat`). Non-null means this is
  /// a vector index; the SQL emitter chooses the appropriate
  /// `USING <method> (col <opclass>)` form.
  final VectorIndexMethod? using;

  /// Distance metric used to pick the pgvector opclass. Only consulted
  /// when [using] is non-null.
  final VectorDistance? distance;

  const IndexDefinition({
    required this.name,
    required this.columns,
    this.isUnique = false,
    this.using,
    this.distance,
  });
}

/// Model definition
class ModelDefinition {
  final String name;
  final String tableName;
  final List<ColumnDefinition> columns;
  final List<IndexDefinition> indexes;
  final List<CheckConstraint> checks;

  /// Source file URI when this model was loaded via [SchemaDefinition.fromProject].
  final Uri? sourceUrl;

  const ModelDefinition({
    required this.name,
    required this.tableName,
    required this.columns,
    this.indexes = const [],
    this.checks = const [],
    this.sourceUrl,
  });

  /// All CHECK constraints: named model-level plus synthesized column-level.
  List<CheckConstraint> get allChecks {
    final out = List<CheckConstraint>.of(checks);
    for (final col in columns) {
      final expr = col.checkExpression;
      if (expr == null || expr.isEmpty) continue;
      out.add(CheckConstraint(
        name: '${tableName}_${col.name}_check',
        expression: expr,
        columnName: col.name,
      ));
    }
    return out;
  }

  /// Get all regular columns (non-relationship)
  List<ColumnDefinition> get regularColumns =>
      columns.where((col) => !col.isRelationship).toList();

  /// Get all foreign key columns
  List<ColumnDefinition> get foreignKeyColumns =>
      columns.where((col) => col.type == ColumnType.foreignKey).toList();

  /// Get all many-to-many relationships
  List<ColumnDefinition> get manyToManyColumns =>
      columns.where((col) => col.type == ColumnType.manyToMany).toList();

  /// Get primary key column
  ColumnDefinition? get primaryKey =>
      columns.where((col) => col.constraints.isPrimary).firstOrNull;

  /// Get unique columns
  List<ColumnDefinition> get uniqueColumns =>
      columns.where((col) => col.constraints.isUnique).toList();

  /// Get indexed columns
  List<ColumnDefinition> get indexedColumns =>
      columns.where((col) => col.constraints.isIndex).toList();
}

/// Complete schema definition
class SchemaDefinition {
  final List<ModelDefinition> models;
  final List<EnumDefinition> enums;
  final Map<String, ModelDefinition> _modelMap = {};
  final Map<String, EnumDefinition> _enumMap = {};

  SchemaDefinition({
    required this.models,
    this.enums = const [],
  }) {
    for (final model in models) {
      _modelMap[model.name] = model;
    }
    for (final e in enums) {
      _enumMap[e.name] = e;
    }
  }

  /// Get model by name
  ModelDefinition? getModel(String name) => _modelMap[name];

  /// Get enum by name
  EnumDefinition? getEnum(String name) => _enumMap[name];

  /// Get all model names
  List<String> get modelNames => models.map((m) => m.name).toList();

  /// Get all enum names
  List<String> get enumNames => enums.map((e) => e.name).toList();

  /// Get relationships between models
  List<RelationshipInfo> get relationships {
    final relationships = <RelationshipInfo>[];

    for (final model in models) {
      for (final column in model.columns) {
        if (column.isRelationship && column.relationship != null) {
          relationships.add(RelationshipInfo(
            fromModel: model.name,
            toModel: column.relationship!.references!,
            fromColumn: column.name,
            reverseName: column.relationship!.reverseName,
            isManyToMany: column.relationship!.isManyToMany,
            isUnique: column.constraints.isUnique,
          ));
        }
      }
    }

    return relationships;
  }

  /// Parse [yamlContent] into a [SchemaDefinition], throwing
  /// [SchemaValidationException] with one entry per detected mistake
  /// (typo'd key, unknown type, invalid constraint value, dangling
  /// reference, …).
  ///
  /// Pass [sourceUrl] so the rendered diagnostics can point at the
  /// original file path; build_runner does this automatically.
  ///
  /// [projectModelNames] / [projectEnums] override the file-local name
  /// sets so a single file can resolve relations and enum types declared
  /// in other project schema files (see [fromProject]).
  factory SchemaDefinition.fromYaml(
    String yamlContent, {
    Uri? sourceUrl,
    Set<String>? projectModelNames,
    Map<String, EnumDefinition>? projectEnums,
  }) {
    final parser = _SchemaParser(yamlContent, sourceUrl);
    return parser.parse(
      projectModelNames: projectModelNames,
      projectEnums: projectEnums,
    );
  }

  static Future<SchemaDefinition> fromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Schema file not found: $filePath');
    }

    final content = await file.readAsString();
    return SchemaDefinition.fromYaml(content, sourceUrl: file.uri);
  }

  /// Load and merge every schema file into one project [SchemaDefinition]
  /// so models/enums may reference each other across files.
  ///
  /// [files] should already be sorted for deterministic output. Throws
  /// [SchemaValidationException] aggregating errors from every file.
  static Future<SchemaDefinition> fromProject(List<File> files) async {
    if (files.isEmpty) {
      throw SchemaValidationException([
        SchemaError(
          code: 'empty_schema',
          message: 'no *.gisila.yaml schema files found in the project',
          span: SourceFile.fromString('').span(0),
          hint: 'add a model file under lib/ ending in .gisila.yaml',
        ),
      ]);
    }

    final errors = <SchemaError>[];
    final contents = <({File file, String content, Uri uri})>[];
    for (final file in files) {
      final content = await file.readAsString();
      contents.add((file: file, content: content, uri: file.uri));
    }

    // Pass 1: collect enums + model names from every file.
    final enumsByName = <String, EnumDefinition>{};
    final enumSource = <String, Uri>{};
    final modelNames = <String>{};
    final modelNameSource = <String, Uri>{};

    for (final entry in contents) {
      final parser = _SchemaParser(entry.content, entry.uri);
      final root = parser._loadRoot();
      if (root == null) {
        errors.addAll(parser._errors);
        continue;
      }
      final localEnums = parser._parseEnumsBlock(root);
      errors.addAll(parser._errors.where((e) => e.level == SchemaErrorLevel.error));
      parser._errors.clear();

      for (final e in localEnums) {
        final prior = enumsByName[e.name];
        if (prior != null) {
          if (!_enumValuesEqual(prior.values, e.values)) {
            errors.add(SchemaError(
              code: 'duplicate_enum',
              message: 'enum "${e.name}" is declared in multiple files with '
                  'different values',
              span: SourceFile.fromString(entry.content, url: entry.uri)
                  .span(0, entry.content.isEmpty ? 0 : 1),
              notes: [
                'also declared in ${enumSource[e.name]}',
                'values here: ${e.values.join(", ")}',
                'values there: ${prior.values.join(", ")}',
              ],
            ));
          }
          continue;
        }
        enumsByName[e.name] = e;
        enumSource[e.name] = entry.uri;
      }

      final names = parser._collectModelNames(root);
      for (final n in names) {
        if (modelNames.contains(n) && modelNameSource[n] != entry.uri) {
          // Duplicate across files — record now; still keep the name so
          // refs resolve while we report the collision.
          errors.add(SchemaError(
            code: 'duplicate_model',
            message: 'model "$n" is declared in multiple schema files',
            span: SourceFile.fromString(entry.content, url: entry.uri)
                .span(0, entry.content.isEmpty ? 0 : 1),
            notes: ['also declared in ${modelNameSource[n]}'],
          ));
        }
        modelNames.add(n);
        modelNameSource.putIfAbsent(n, () => entry.uri);
      }
      // Naming-convention warnings from collect — keep non-fatal.
      errors.addAll(parser._errors);
      parser._errors.clear();
    }

    for (final name in enumsByName.keys.toSet().intersection(modelNames)) {
      errors.add(SchemaError(
        code: 'enum_model_collision',
        message: '"$name" is declared as both an enum and a model',
        span: SourceFile.fromString('').span(0),
        hint: 'rename the enum or the model so the names are unique',
        notes: [
          if (enumSource[name] != null) 'enum in ${enumSource[name]}',
          if (modelNameSource[name] != null) 'model in ${modelNameSource[name]}',
        ],
      ));
    }

    if (errors.any((e) => e.level == SchemaErrorLevel.error)) {
      throw SchemaValidationException(errors);
    }

    // Pass 2: parse each file against the global name sets.
    final models = <ModelDefinition>[];
    final seenModels = <String>{};
    for (final entry in contents) {
      try {
        final part = SchemaDefinition.fromYaml(
          entry.content,
          sourceUrl: entry.uri,
          projectModelNames: modelNames,
          projectEnums: enumsByName,
        );
        for (final m in part.models) {
          if (!seenModels.add(m.name)) continue; // already reported
          models.add(ModelDefinition(
            name: m.name,
            tableName: m.tableName,
            columns: m.columns,
            indexes: m.indexes,
            checks: m.checks,
            sourceUrl: entry.uri,
          ));
        }
      } on SchemaValidationException catch (e) {
        errors.addAll(e.errors);
      }
    }

    if (errors.any((e) => e.level == SchemaErrorLevel.error)) {
      throw SchemaValidationException(errors);
    }

    // Cross-file reverse_name / collision checks on the merged model set.
    final crossErrors = <SchemaError>[];
    _crossValidateModels(models, crossErrors);
    errors.addAll(crossErrors);
    if (errors.any((e) => e.level == SchemaErrorLevel.error)) {
      throw SchemaValidationException(errors);
    }

    models.sort((a, b) => a.name.compareTo(b.name));
    return SchemaDefinition(
      models: models,
      enums: enumsByName.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
    );
  }
}

/// Serialize [schema] to YAML that [SchemaDefinition.fromYaml] can reload.
///
/// Used for project-level snapshots under `.gisila/schema_snapshots/`.
/// Round-trip fidelity is sufficient for [SchemaDiffer]; cosmetic YAML
/// style may differ from hand-authored sources.
String emitSchemaYaml(SchemaDefinition schema) {
  final buf = StringBuffer();
  buf.writeln('# Generated by gisila — project schema snapshot.');
  buf.writeln('# Do not edit; regenerated by `dart run gisila_orm:generate`.');
  buf.writeln();

  final enums = [...schema.enums]..sort((a, b) => a.name.compareTo(b.name));
  if (enums.isNotEmpty) {
    buf.writeln('enums:');
    for (final e in enums) {
      buf.writeln('  ${e.name}:');
      for (final v in e.values) {
        buf.writeln('    - $v');
      }
    }
    buf.writeln();
  }

  final models = [...schema.models]..sort((a, b) => a.name.compareTo(b.name));
  for (final model in models) {
    buf.writeln('${model.name}:');
    final defaultTable = _pluralSnakeCase(_toSnakeCase(model.name));
    if (model.tableName != defaultTable) {
      buf.writeln('  db_table: ${model.tableName}');
    }
    buf.writeln('  columns:');
    for (final col in model.columns) {
      buf.writeln('    ${col.name}:');
      for (final line in _emitColumnYamlLines(col)) {
        buf.writeln('      $line');
      }
    }
    if (model.checks.isNotEmpty) {
      buf.writeln('  checks:');
      for (final check in model.checks) {
        buf.writeln('    ${check.name}:');
        buf.writeln('      expression: ${_yamlScalar(check.expression)}');
      }
    }
    if (model.indexes.isNotEmpty) {
      buf.writeln('  indexes:');
      for (final index in model.indexes) {
        buf.writeln('    ${index.name}:');
        buf.writeln(
            '      columns: [${index.columns.map(_yamlScalar).join(', ')}]');
        if (index.isUnique) {
          buf.writeln('      unique: true');
        }
        if (index.using != null) {
          buf.writeln('      using: ${index.using!.name}');
        }
        if (index.distance != null) {
          buf.writeln('      distance: ${index.distance!.alias}');
        }
      }
    }
    buf.writeln();
  }
  return buf.toString();
}

List<String> _emitColumnYamlLines(ColumnDefinition col) {
  final lines = <String>[];
  lines.add('type: ${_yamlTypeString(col)}');

  final c = col.constraints;
  lines.add('is_null: ${c.isNull}');
  if (c.isUnique) lines.add('is_unique: true');
  if (c.isIndex) lines.add('is_index: true');
  if (c.isPrimary) lines.add('is_primary: true');
  if (!c.allowBlank) lines.add('allow_blank: false');
  if (c.maxLength != null &&
      (col.type == ColumnType.varchar ||
          (col.type == ColumnType.array &&
              col.array?.elementType == ColumnType.varchar))) {
    lines.add('max_length: ${c.maxLength}');
  }
  if (c.defaultValue != null) {
    lines.add('default: ${_yamlScalar(c.defaultValue)}');
  }
  if (col.checkExpression != null && col.checkExpression!.isNotEmpty) {
    lines.add('check: ${_yamlScalar(col.checkExpression)}');
  }

  final rel = col.relationship;
  if (rel != null) {
    if (rel.references != null) {
      lines.add('references: ${rel.references}');
    }
    if (rel.reverseName != null) {
      lines.add('reverse_name: ${rel.reverseName}');
    }
    if (rel.isManyToMany) {
      lines.add('many_to_many: true');
    }
    if (rel.onDelete != null) {
      lines.add('on_delete: ${rel.onDelete}');
    }
    if (rel.onUpdate != null) {
      lines.add('on_update: ${rel.onUpdate}');
    }
  }

  final vector = col.vector;
  if (vector != null) {
    lines.add('dimensions: ${vector.dimensions}');
    if (vector.indexMethod != VectorIndexMethod.hnsw) {
      lines.add('index_method: ${vector.indexMethod.name}');
    }
    if (vector.distance != VectorDistance.l2) {
      lines.add('distance: ${vector.distance.alias}');
    }
  }

  return lines;
}

String _yamlTypeString(ColumnDefinition col) {
  switch (col.type) {
    case ColumnType.foreignKey:
      return 'foreign_key';
    case ColumnType.manyToMany:
      return col.relationship?.references ?? 'foreign_key';
    case ColumnType.enumType:
      return col.enumConfig?.enumName ?? 'text';
    case ColumnType.array:
      final el = col.array?.elementType.name ?? 'text';
      return '$el[]';
    case ColumnType.varchar:
    case ColumnType.text:
    case ColumnType.integer:
    case ColumnType.bigint:
    case ColumnType.boolean:
    case ColumnType.date:
    case ColumnType.timestamp:
    case ColumnType.decimal:
    case ColumnType.json:
    case ColumnType.uuid:
    case ColumnType.vector:
    case ColumnType.point:
    case ColumnType.box:
    case ColumnType.circle:
    case ColumnType.lseg:
      return col.type.name;
  }
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is bool || value is num) return value.toString();
  final s = value.toString();
  if (s.isEmpty) return "''";
  if (RegExp(r'^[A-Za-z0-9_./()-]+$').hasMatch(s) &&
      !const {'true', 'false', 'null', 'yes', 'no'}.contains(s.toLowerCase())) {
    return s;
  }
  final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

bool _enumValuesEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Reverse-name collision checks that do not require a single YAML root.
void _crossValidateModels(
  List<ModelDefinition> models,
  List<SchemaError> errors,
) {
  final modelByName = {for (final m in models) m.name: m};
  final reverseSeen = <String, Map<String, String>>{};

  for (final model in models) {
    for (final col in model.columns) {
      final rel = col.relationship;
      if (rel == null) continue;
      final reverseName = rel.reverseName;
      if (reverseName == null) continue;

      final span = SourceFile.fromString(
        '',
        url: model.sourceUrl,
      ).span(0);

      final target = modelByName[rel.references];
      if (target != null &&
          target.columns.any((c) => c.name == reverseName)) {
        errors.add(SchemaError(
          code: 'reverse_name_collision',
          message:
              '`reverse_name: $reverseName` collides with existing column '
              '"${target.name}.$reverseName"',
          span: span,
          hint: 'pick a different `reverse_name` to avoid shadowing',
        ));
      }

      final byTarget = reverseSeen.putIfAbsent(rel.references!, () => {});
      if (byTarget.containsKey(reverseName)) {
        errors.add(SchemaError(
          code: 'reverse_name_collision',
          message:
              'two relationships define `reverse_name: $reverseName` on "${rel.references}"',
          span: span,
          notes: ['first defined at "${byTarget[reverseName]}"'],
        ));
      } else {
        byTarget[reverseName] = '${model.name}.${col.name}';
      }
    }
  }
}

/// Relationship information between models
class RelationshipInfo {
  final String fromModel;
  final String toModel;
  final String fromColumn;
  final String? reverseName;
  final bool isManyToMany;

  /// When true, the belongs-to side is unique and the inverse should be
  /// treated as HasOne rather than HasMany.
  final bool isUnique;

  const RelationshipInfo({
    required this.fromModel,
    required this.toModel,
    required this.fromColumn,
    this.reverseName,
    this.isManyToMany = false,
    this.isUnique = false,
  });

  /// Physical FK column on the declaring (child) table.
  String get physicalFromColumn => physicalForeignKeyColumnName(fromColumn);

  String get junctionTableName => isManyToMany
      ? ([
          _pluralSnakeCase(_toSnakeCase(fromModel)),
          _pluralSnakeCase(_toSnakeCase(toModel))
        ]..sort())
          .join('_')
      : '';
}

/// Physical SQL column name for a foreign-key YAML field [logicalName].
///
/// Appends `_id` unless [logicalName] already ends with `_id`.
String physicalForeignKeyColumnName(String logicalName) =>
    logicalName.endsWith('_id') ? logicalName : '${logicalName}_id';

String _camelCaseIdent(String s) {
  final parts = s.split('_');
  if (parts.isEmpty) return s;
  final head = parts.first;
  final tail = parts
      .skip(1)
      .map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1));
  return head + tail.join();
}

/// Extension to provide firstOrNull functionality
extension IterableExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

const _builtinTypeStrings = <String>{
  'varchar',
  'text',
  'integer',
  'bigint',
  'boolean',
  'date',
  'timestamp',
  'decimal',
  'json',
  'uuid',
  'vector',
  'point',
  'box',
  'circle',
  'lseg',
};

/// Scalar builtins allowed as array element types (`varchar[]`, …).
const _arrayElementTypes = <String>{
  'varchar',
  'text',
  'integer',
  'bigint',
  'boolean',
  'date',
  'timestamp',
  'decimal',
  'uuid',
};

/// Reserved top-level keys that are not model definitions.
const _topLevelReservedKeys = <String>{'enums'};

const _knownModelKeys = <String>{'columns', 'indexes', 'db_table', 'checks'};

const _knownColumnKeys = <String>{
  'type',
  'is_null',
  'is_unique',
  'is_index',
  'is_primary',
  'allow_blank',
  'default',
  'max_length',
  'check',
  'references',
  'reverse_name',
  'many_to_many',
  'on_delete',
  'on_update',
  // pgvector-only.
  'dimensions',
  'index_method',
  'distance',
};

const _knownCheckKeys = <String>{'expression'};

/// YAML type aliases that always mean "foreign key / belongs-to" and
/// require a `references:` target model.
const _foreignKeyTypeAliases = <String>{
  'foreign_key',
  'foreignkey',
};

const _knownIndexKeys = <String>{
  'columns',
  'unique',
  // pgvector-only: explicit vector indexes in the `indexes:` block.
  'using',
  'distance',
};

const _validReferentialActions = <String>{
  'NO ACTION',
  'RESTRICT',
  'CASCADE',
  'SET NULL',
  'SET DEFAULT',
};

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Stricter pattern for column names: only lowercase letters, digits, and
/// underscores. This catches accidental camelCase like `createdAt` at
/// schema-parse time rather than letting it silently reach the database.
final RegExp _columnNamePattern = RegExp(r'^[a-z_][a-z0-9_]*$');

/// Internal parser that walks a [YamlNode] tree, accumulates
/// [SchemaError]s, and finally builds a [SchemaDefinition] (or throws
/// [SchemaValidationException] if anything went wrong).
class _SchemaParser {
  _SchemaParser(this._content, this._sourceUrl);

  final String _content;
  final Uri? _sourceUrl;
  final List<SchemaError> _errors = [];

  SchemaDefinition parse({
    Set<String>? projectModelNames,
    Map<String, EnumDefinition>? projectEnums,
  }) {
    final root = _loadRoot();
    if (root == null) {
      throw SchemaValidationException(_errors);
    }

    final localEnums = _parseEnumsBlock(root);
    final enumsByName = projectEnums ??
        {for (final e in localEnums) e.name: e};
    final enumNames = enumsByName.keys.toSet();
    final localModelNames = _collectModelNames(root);
    final modelNames = projectModelNames ?? localModelNames;

    // Only enforce enum/model collision against names visible in this
    // parse. Project-wide collisions are handled in [fromProject].
    if (projectModelNames == null && projectEnums == null) {
      for (final name in enumNames.intersection(modelNames)) {
        _errors.add(SchemaError(
          code: 'enum_model_collision',
          message: '"$name" is declared as both an enum and a model',
          span: _wholeFileSpan(),
          hint: 'rename the enum or the model so the names are unique',
        ));
      }
    }

    final models = <ModelDefinition>[];
    final seen = <String, SourceSpan>{};
    for (final entry in root.nodes.entries) {
      final keyNode = entry.key as YamlNode;
      final modelNameValue = keyNode.value;
      if (modelNameValue is! String || modelNameValue.isEmpty) {
        // Already reported by _collectModelNames.
        continue;
      }
      if (_topLevelReservedKeys.contains(modelNameValue)) {
        continue;
      }
      if (!_identifierPattern.hasMatch(modelNameValue)) {
        // Already reported by _collectModelNames.
        continue;
      }

      final priorSpan = seen[modelNameValue];
      if (priorSpan != null) {
        _errors.add(SchemaError(
          code: 'duplicate_model',
          message: 'model "$modelNameValue" is declared more than once',
          span: keyNode.span,
          notes: ['first declared at line ${priorSpan.start.line + 1}'],
        ));
        continue;
      }
      seen[modelNameValue] = keyNode.span;

      final model = _parseModel(
        modelNameValue,
        keyNode,
        entry.value,
        modelNames,
        enumsByName: enumsByName,
      );
      if (model != null) {
        models.add(ModelDefinition(
          name: model.name,
          tableName: model.tableName,
          columns: model.columns,
          indexes: model.indexes,
          checks: model.checks,
          sourceUrl: _sourceUrl,
        ));
      }
    }

    _crossValidate(models, root);

    if (_errors.isNotEmpty) throw SchemaValidationException(_errors);
    // Return file-local enums; [fromProject] unions them across files.
    return SchemaDefinition(models: models, enums: localEnums);
  }

  YamlMap? _loadRoot() {
    YamlNode node;
    try {
      node = loadYamlNode(_content, sourceUrl: _sourceUrl);
    } on YamlException catch (e) {
      // The yaml package surfaces duplicate map keys as a generic
      // YamlException; relabel them so users see a focused message
      // ("the same column/model was declared twice") instead of the
      // raw parser string.
      if (e.message.toLowerCase().contains('duplicate mapping key')) {
        _errors.add(SchemaError(
          code: 'duplicate_key',
          message:
              'duplicate key — model, column, and index names must be unique',
          span: e.span ?? _wholeFileSpan(),
          hint: 'remove or rename one of the two entries with this key',
        ));
      } else {
        _errors.add(SchemaError(
          code: 'invalid_yaml',
          message: 'YAML parse error: ${e.message}',
          span: e.span ?? _wholeFileSpan(),
        ));
      }
      return null;
    }
    if (node is YamlScalar && node.value == null) {
      _errors.add(SchemaError(
        code: 'empty_schema',
        message: 'schema file is empty',
        span: _wholeFileSpan(),
        hint: 'declare at least one model, e.g. `User: { columns: { ... } }`',
      ));
      return null;
    }
    if (node is! YamlMap) {
      _errors.add(SchemaError(
        code: 'expected_map',
        message: 'top-level schema must be a YAML map of model definitions',
        span: node.span,
        hint: 'wrap your tables in `ModelName:` headers',
      ));
      return null;
    }
    return node;
  }

  /// Walk the root once just to collect every valid model name, so
  /// later relationship validation can resolve references even if
  /// some models are declared after they're referenced.
  Set<String> _collectModelNames(YamlMap root) {
    final names = <String>{};
    for (final entry in root.nodes.entries) {
      final keyNode = entry.key as YamlNode;
      final v = keyNode.value;
      if (v is! String || v.isEmpty) {
        _errors.add(SchemaError(
          code: 'invalid_model_name',
          message: 'model names must be non-empty strings',
          span: keyNode.span,
        ));
        continue;
      }
      if (_topLevelReservedKeys.contains(v)) {
        continue;
      }
      if (!_identifierPattern.hasMatch(v)) {
        _errors.add(SchemaError(
          code: 'invalid_model_name',
          message: 'invalid model name "$v"',
          span: keyNode.span,
          hint:
              'use a PascalCase identifier (letters, digits, underscores; cannot start with a digit)',
        ));
        continue;
      }
      if (v[0] != v[0].toUpperCase()) {
        _errors.add(SchemaError(
          code: 'naming_convention',
          message: 'model name "$v" should be PascalCase',
          level: SchemaErrorLevel.warning,
          span: keyNode.span,
          hint:
              'rename to "${v[0].toUpperCase()}${v.substring(1)}" to follow gisila conventions',
        ));
      }
      names.add(v);
    }
    return names;
  }

  List<EnumDefinition> _parseEnumsBlock(YamlMap root) {
    final enumsNode = root.nodes['enums'];
    if (enumsNode == null) return const [];
    if (enumsNode is! YamlMap) {
      _errors.add(SchemaError(
        code: 'expected_map',
        message: '`enums` must be a map of enum name → value list',
        span: enumsNode.span,
        hint: 'e.g. `enums: { TeamRole: [viewer, admin] }`',
      ));
      return const [];
    }

    final enums = <EnumDefinition>[];
    final seen = <String, SourceSpan>{};
    for (final entry in enumsNode.nodes.entries) {
      final keyNode = entry.key as YamlNode;
      final name = keyNode.value;
      if (name is! String || name.isEmpty || !_identifierPattern.hasMatch(name)) {
        _errors.add(SchemaError(
          code: 'invalid_enum_name',
          message: 'enum names must be non-empty PascalCase identifiers',
          span: keyNode.span,
        ));
        continue;
      }
      if (!_isPascalCaseLike(name)) {
        _errors.add(SchemaError(
          code: 'naming_convention',
          message: 'enum name "$name" should be PascalCase',
          level: SchemaErrorLevel.warning,
          span: keyNode.span,
        ));
      }
      final prior = seen[name];
      if (prior != null) {
        _errors.add(SchemaError(
          code: 'duplicate_enum',
          message: 'enum "$name" is declared more than once',
          span: keyNode.span,
        ));
        continue;
      }
      seen[name] = keyNode.span;

      final valuesNode = entry.value;
      if (valuesNode is! YamlList || valuesNode.isEmpty) {
        _errors.add(SchemaError(
          code: 'invalid_enum_values',
          message: 'enum "$name" must be a non-empty list of values',
          span: valuesNode.span,
        ));
        continue;
      }
      final values = <String>[];
      final seenValues = <String>{};
      for (final item in valuesNode.nodes) {
        final v = item.value;
        if (v is! String || !_identifierPattern.hasMatch(v)) {
          _errors.add(SchemaError(
            code: 'invalid_enum_value',
            message: 'enum "$name" values must be identifiers',
            span: item.span,
          ));
          continue;
        }
        if (!seenValues.add(v)) {
          _errors.add(SchemaError(
            code: 'duplicate_enum_value',
            message: 'enum "$name" repeats value "$v"',
            span: item.span,
          ));
          continue;
        }
        values.add(v);
      }
      if (values.isNotEmpty) {
        enums.add(EnumDefinition(name: name, values: values));
      }
    }
    return enums;
  }

  ModelDefinition? _parseModel(
    String modelName,
    YamlNode keyNode,
    YamlNode valueNode,
    Set<String> modelNames, {
    Map<String, EnumDefinition> enumsByName = const {},
  }) {
    if (valueNode is! YamlMap) {
      _errors.add(SchemaError(
        code: 'expected_map',
        message: 'model "$modelName" must be a map',
        span: valueNode.span,
        hint: 'expected `columns:` (with optional `db_table` and `indexes`)',
      ));
      return null;
    }

    _checkUnknownKeys(
      ownerLabel: 'model "$modelName"',
      mapNode: valueNode,
      knownKeys: _knownModelKeys,
    );

    // db_table — defaults to plural snake_case of the model name so that
    // the common convention is followed and PostgreSQL reserved words like
    // `user` and `order` are avoided automatically.
    String tableName = _pluralSnakeCase(_toSnakeCase(modelName));
    final dbTableNode = valueNode.nodes['db_table'];
    if (dbTableNode != null) {
      final v = dbTableNode.value;
      if (v is String && v.isNotEmpty && _columnNamePattern.hasMatch(v)) {
        tableName = v;
        // Warn when an explicit db_table value is a PostgreSQL reserved word.
        if (_pgReservedWords.contains(v.toLowerCase())) {
          _errors.add(SchemaError(
            code: 'reserved_table_name',
            message: 'table name "$v" for model "$modelName" is a PostgreSQL '
                'reserved keyword',
            span: dbTableNode.span,
            hint: 'choose a different name (e.g. "${v}s") to avoid '
                'ambiguity — or keep it and ensure all queries use quoted '
                'identifiers',
          ));
        }
      } else {
        _errors.add(SchemaError(
          code: 'invalid_db_table',
          message:
              '`db_table` of "$modelName" must be a non-empty SQL identifier',
          span: dbTableNode.span,
          hint: 'use snake_case letters, digits, and underscores only',
        ));
      }
    } else if (_pgReservedWords.contains(tableName.toLowerCase())) {
      // Auto-derived name still collides after pluralisation (shouldn't
      // happen with basic English words, but guard just in case).
      _errors.add(SchemaError(
        code: 'reserved_table_name',
        message: 'auto-derived table name "$tableName" for model "$modelName" '
            'is a PostgreSQL reserved keyword',
        span: keyNode.span,
        hint: 'add `db_table: ${tableName}s` under "$modelName:" to pick '
            'an explicit safe name',
      ));
    }

    // columns
    final columnsNode = valueNode.nodes['columns'];
    if (columnsNode == null) {
      _errors.add(SchemaError(
        code: 'missing_columns',
        message: 'model "$modelName" is missing the required `columns` block',
        span: keyNode.span,
        hint: 'add at least one column under `columns:`',
      ));
      return null;
    }
    if (columnsNode is! YamlMap) {
      _errors.add(SchemaError(
        code: 'expected_map',
        message: '`columns` of model "$modelName" must be a map',
        span: columnsNode.span,
      ));
      return null;
    }

    final columns = <ColumnDefinition>[];
    final seenColumns = <String, SourceSpan>{};
    var hasPrimary = false;
    for (final entry in columnsNode.nodes.entries) {
      final colKey = entry.key as YamlNode;
      final colNameValue = colKey.value;
      if (colNameValue is! String || colNameValue.isEmpty) {
        _errors.add(SchemaError(
          code: 'invalid_column_name',
          message: 'column name must be a non-empty string',
          span: colKey.span,
        ));
        continue;
      }
      if (!_columnNamePattern.hasMatch(colNameValue)) {
        _errors.add(SchemaError(
          code: 'invalid_column_name',
          message: 'invalid column name "$colNameValue"',
          span: colKey.span,
          hint: 'use snake_case letters, digits, and underscores only '
              '(e.g. "created_at" not "createdAt")',
        ));
        continue;
      }
      final priorSpan = seenColumns[colNameValue];
      if (priorSpan != null) {
        _errors.add(SchemaError(
          code: 'duplicate_column',
          message:
              'column "$colNameValue" is declared more than once in "$modelName"',
          span: colKey.span,
          notes: ['first declared at line ${priorSpan.start.line + 1}'],
        ));
        continue;
      }
      seenColumns[colNameValue] = colKey.span;

      final col = _parseColumn(
        modelName: modelName,
        columnName: colNameValue,
        keyNode: colKey,
        valueNode: entry.value,
        modelNames: modelNames,
        enumsByName: enumsByName,
      );
      if (col == null) continue;
      columns.add(col);
      if (col.constraints.isPrimary) hasPrimary = true;
    }

    if (!hasPrimary) {
      columns.insert(
        0,
        const ColumnDefinition(
          name: 'id',
          type: ColumnType.integer,
          constraints: ColumnConstraints(
            isPrimary: true,
            isNull: false,
            isUnique: true,
            isIndex: true,
          ),
        ),
      );
    }

    // indexes
    final indexes = <IndexDefinition>[];
    final indexesNode = valueNode.nodes['indexes'];
    if (indexesNode != null) {
      if (indexesNode is! YamlMap) {
        _errors.add(SchemaError(
          code: 'expected_map',
          message: '`indexes` of model "$modelName" must be a map',
          span: indexesNode.span,
        ));
      } else {
        for (final entry in indexesNode.nodes.entries) {
          final idxKey = entry.key as YamlNode;
          final idxNameValue = idxKey.value;
          if (idxNameValue is! String || idxNameValue.isEmpty) {
            _errors.add(SchemaError(
              code: 'invalid_index_name',
              message: 'index name must be a non-empty string',
              span: idxKey.span,
            ));
            continue;
          }
          final idx = _parseIndex(
            modelName: modelName,
            indexName: idxNameValue,
            valueNode: entry.value,
            columns: columns,
          );
          if (idx != null) indexes.add(idx);
        }
      }
    }

    // Named table-level CHECK constraints.
    final checks = <CheckConstraint>[];
    final checksNode = valueNode.nodes['checks'];
    if (checksNode != null) {
      if (checksNode is! YamlMap) {
        _errors.add(SchemaError(
          code: 'expected_map',
          message: '`checks` of model "$modelName" must be a map',
          span: checksNode.span,
        ));
      } else {
        for (final entry in checksNode.nodes.entries) {
          final checkKey = entry.key as YamlNode;
          final checkName = checkKey.value;
          if (checkName is! String || checkName.isEmpty) {
            _errors.add(SchemaError(
              code: 'invalid_check_name',
              message: 'check constraint name must be a non-empty string',
              span: checkKey.span,
            ));
            continue;
          }
          final checkValue = entry.value;
          if (checkValue is! YamlMap) {
            _errors.add(SchemaError(
              code: 'expected_map',
              message: 'check "$checkName" must be a map with `expression:`',
              span: checkValue.span,
            ));
            continue;
          }
          _checkUnknownKeys(
            ownerLabel: 'check "$checkName"',
            mapNode: checkValue,
            knownKeys: _knownCheckKeys,
          );
          final exprNode = checkValue.nodes['expression'];
          final expr = exprNode?.value;
          if (expr is! String || expr.trim().isEmpty) {
            _errors.add(SchemaError(
              code: 'invalid_check',
              message: 'check "$checkName" requires a non-empty `expression`',
              span: exprNode?.span ?? checkValue.span,
            ));
            continue;
          }
          checks.add(CheckConstraint(
            name: checkName,
            expression: expr.trim(),
          ));
        }
      }
    }

    return ModelDefinition(
      name: modelName,
      tableName: tableName,
      columns: columns,
      indexes: indexes,
      checks: checks,
    );
  }

  ColumnDefinition? _parseColumn({
    required String modelName,
    required String columnName,
    required YamlNode keyNode,
    required YamlNode valueNode,
    required Set<String> modelNames,
    Map<String, EnumDefinition> enumsByName = const {},
  }) {
    if (valueNode is! YamlMap) {
      _errors.add(SchemaError(
        code: 'expected_map',
        message: 'column "$modelName.$columnName" must be a map',
        span: valueNode.span,
        hint: 'use the form `$columnName: { type: varchar, is_null: false }`',
      ));
      return null;
    }

    _checkUnknownKeys(
      ownerLabel: 'column "$modelName.$columnName"',
      mapNode: valueNode,
      knownKeys: _knownColumnKeys,
    );

    final typeNode = valueNode.nodes['type'];
    if (typeNode == null) {
      _errors.add(SchemaError(
        code: 'missing_type',
        message:
            'column "$modelName.$columnName" is missing required `type` field',
        span: keyNode.span,
        hint: 'add `type: varchar` (or another supported type)',
      ));
      return null;
    }
    final typeValue = typeNode.value;
    if (typeValue is! String || typeValue.isEmpty) {
      _errors.add(SchemaError(
        code: 'invalid_type',
        message:
            '`type` of "$modelName.$columnName" must be a non-empty string',
        span: typeNode.span,
      ));
      return null;
    }

    final typeLower = typeValue.toLowerCase();
    final isArrayType = typeLower.endsWith('[]');
    final arrayElementName =
        isArrayType ? typeLower.substring(0, typeLower.length - 2) : null;
    final isForeignKeyAlias = _foreignKeyTypeAliases.contains(typeLower);
    final isBuiltin = !isForeignKeyAlias &&
        !isArrayType &&
        _builtinTypeStrings.contains(typeLower);
    final isEnumType =
        !isBuiltin && !isForeignKeyAlias && !isArrayType && enumsByName.containsKey(typeValue);
    final referencesNode = valueNode.nodes['references'];
    final manyToManyNode = valueNode.nodes['many_to_many'];
    final isM2M = manyToManyNode?.value == true;
    final hasReferences = referencesNode != null;
    final looksLikeModel = !isBuiltin &&
        !isForeignKeyAlias &&
        !isArrayType &&
        !isEnumType &&
        _isPascalCaseLike(typeValue);

    // Validate constraints unconditionally so the user sees every
    // mistake (bad bool, bad default, ...) on this column in one
    // shot, even when the `type:` is itself invalid.
    final constraints = _parseConstraints(
      modelName,
      columnName,
      valueNode,
      columnTypeHint: isArrayType ? 'varchar' : typeLower,
    );

    String? checkExpression;
    final checkNode = valueNode.nodes['check'];
    if (checkNode != null) {
      final v = checkNode.value;
      if (v is String && v.trim().isNotEmpty) {
        checkExpression = v.trim();
      } else {
        _errors.add(SchemaError(
          code: 'invalid_check',
          message:
              '`check` on "$modelName.$columnName" must be a non-empty string',
          span: checkNode.span,
        ));
      }
    }

    ColumnType type;
    RelationshipConfig? relationship;
    VectorConfig? vectorConfig;
    ArrayConfig? arrayConfig;
    EnumConfig? enumConfig;

    if (isArrayType) {
      if (!_arrayElementTypes.contains(arrayElementName)) {
        _errors.add(SchemaError(
          code: 'invalid_array_element',
          message: 'unsupported array element type "$arrayElementName"',
          span: typeNode.span,
          hint: 'allowed: ${_arrayElementTypes.join(", ")}',
        ));
        return null;
      }
      if (hasReferences || isM2M) {
        _errors.add(SchemaError(
          code: 'invalid_relationship',
          message: 'array columns cannot declare relationships',
          span: typeNode.span,
        ));
      }
      final elementType = _builtinFromString(arrayElementName!)!;
      arrayConfig = ArrayConfig(
        elementType: elementType,
        maxLength:
            elementType == ColumnType.varchar ? constraints.maxLength : null,
      );
      type = ColumnType.array;
    } else if (isEnumType) {
      final def = enumsByName[typeValue]!;
      type = ColumnType.enumType;
      enumConfig = EnumConfig(enumName: def.name, values: def.values);
      if (constraints.defaultValue != null) {
        final dv = constraints.defaultValue.toString();
        if (!def.values.contains(dv)) {
          _errors.add(SchemaError(
            code: 'invalid_enum_default',
            message: 'default "$dv" is not a value of enum "$typeValue"',
            span: valueNode.nodes['default']?.span ?? typeNode.span,
            hint: 'allowed: ${def.values.join(", ")}',
          ));
        }
      }
    } else if (isForeignKeyAlias) {
      // Official `type: foreign_key` form used by apps; requires
      // `references:` (unlike `type: User` where the type itself is the
      // target).
      if (!hasReferences) {
        _errors.add(SchemaError(
          code: 'missing_references',
          message: 'column "$modelName.$columnName" with `type: foreign_key` '
              'requires `references:` naming the target model',
          span: typeNode.span,
          hint: 'add e.g. `references: User`',
        ));
      }
      if (isM2M) {
        _errors.add(SchemaError(
          code: 'invalid_relationship',
          message: '`many_to_many` cannot be combined with `type: foreign_key`; '
              'use `type: <Model>` with `many_to_many: true` instead',
          span: manyToManyNode!.span,
        ));
      }

      String? referencesValue;
      if (hasReferences) {
        final v = referencesNode.value;
        if (v is String && v.isNotEmpty) {
          referencesValue = v;
        } else {
          _errors.add(SchemaError(
            code: 'invalid_references',
            message:
                '`references` on "$modelName.$columnName" must be a non-empty model name',
            span: referencesNode.span,
          ));
        }
      }

      if (referencesValue != null && !modelNames.contains(referencesValue)) {
        final suggestion = suggestClosest(referencesValue, modelNames);
        _errors.add(SchemaError(
          code: 'unknown_reference',
          message:
              '"$modelName.$columnName" references unknown model "$referencesValue"',
          span: referencesNode!.span,
          hint: suggestion != null
              ? 'did you mean "$suggestion"?'
              : modelNames.isEmpty
                  ? 'declare a model with that name first'
                  : 'declared models: ${modelNames.join(", ")}',
        ));
      }

      type = ColumnType.foreignKey;
      relationship = RelationshipConfig(
        references: referencesValue,
        reverseName: _parseReverseName(modelName, columnName, valueNode),
        isManyToMany: false,
        onDelete: _readReferentialAction(
          valueNode.nodes['on_delete'],
          keyName: 'on_delete',
        ),
        onUpdate: _readReferentialAction(
          valueNode.nodes['on_update'],
          keyName: 'on_update',
        ),
      );
    } else if (isBuiltin) {
      if (hasReferences) {
        _errors.add(SchemaError(
          code: 'invalid_relationship',
          message: '`references` is not allowed on builtin type "$typeValue"',
          span: referencesNode.span,
          hint: 'remove `references`, or change `type` to a model name',
        ));
      }
      if (isM2M) {
        _errors.add(SchemaError(
          code: 'invalid_relationship',
          message: '`many_to_many` is not allowed on builtin type "$typeValue"',
          span: manyToManyNode!.span,
        ));
      }
      type = _builtinFromString(typeValue)!;

      // Vector-specific knobs: validate even when type is wrong so the
      // user sees one diagnostic per mistake.
      final dimsNode = valueNode.nodes['dimensions'];
      final indexMethodNode = valueNode.nodes['index_method'];
      final distanceNode = valueNode.nodes['distance'];

      if (type == ColumnType.vector) {
        int? dims;
        if (dimsNode == null) {
          _errors.add(SchemaError(
            code: 'missing_dimensions',
            message: 'vector column "$modelName.$columnName" is missing '
                'required `dimensions:` field',
            span: keyNode.span,
            hint: 'add e.g. `dimensions: 1536`',
          ));
        } else {
          final dv = dimsNode.value;
          if (dv is int && dv > 0) {
            dims = dv;
          } else {
            _errors.add(SchemaError(
              code: 'invalid_dimensions',
              message: '`dimensions` on "$modelName.$columnName" must be a '
                  'positive integer',
              span: dimsNode.span,
            ));
          }
        }

        VectorIndexMethod indexMethod = VectorIndexMethod.hnsw;
        if (indexMethodNode != null) {
          final iv = indexMethodNode.value;
          final parsed = iv is String ? VectorIndexMethod.fromAlias(iv) : null;
          if (parsed == null) {
            final allowed =
                VectorIndexMethod.values.map((e) => e.name).join(', ');
            _errors.add(SchemaError(
              code: 'invalid_index_method',
              message: '`index_method` on "$modelName.$columnName" must be '
                  'one of: $allowed',
              span: indexMethodNode.span,
            ));
          } else {
            indexMethod = parsed;
          }
        }

        VectorDistance distance = VectorDistance.l2;
        if (distanceNode != null) {
          final dv = distanceNode.value;
          final parsed = dv is String ? VectorDistance.fromAlias(dv) : null;
          if (parsed == null) {
            final allowed =
                VectorDistance.values.map((e) => e.alias).join(', ');
            _errors.add(SchemaError(
              code: 'invalid_distance',
              message: '`distance` on "$modelName.$columnName" must be one of: '
                  '$allowed',
              span: distanceNode.span,
            ));
          } else {
            distance = parsed;
          }
        }

        if (dims != null) {
          vectorConfig = VectorConfig(
            dimensions: dims,
            indexMethod: indexMethod,
            distance: distance,
          );
        }
      } else {
        // pgvector knobs only make sense on vector columns.
        for (final entry in <String, YamlNode?>{
          'dimensions': dimsNode,
          'index_method': indexMethodNode,
          'distance': distanceNode,
        }.entries) {
          if (entry.value != null) {
            _errors.add(SchemaError(
              code: 'invalid_vector_option',
              message: '`${entry.key}` is only valid on `type: vector` '
                  '("$modelName.$columnName" is "$typeValue")',
              span: entry.value!.span,
            ));
          }
        }
      }
    } else if (looksLikeModel || hasReferences) {
      type = isM2M ? ColumnType.manyToMany : ColumnType.foreignKey;

      String? referencesValue;
      if (hasReferences) {
        final v = referencesNode.value;
        if (v is String && v.isNotEmpty) {
          referencesValue = v;
        } else {
          _errors.add(SchemaError(
            code: 'invalid_references',
            message:
                '`references` on "$modelName.$columnName" must be a non-empty model name',
            span: referencesNode.span,
          ));
        }
      }
      referencesValue ??= typeValue;

      if (!modelNames.contains(referencesValue)) {
        final suggestion = suggestClosest(referencesValue, modelNames);
        _errors.add(SchemaError(
          code: 'unknown_reference',
          message:
              '"$modelName.$columnName" references unknown model "$referencesValue"',
          span: (referencesNode ?? typeNode).span,
          hint: suggestion != null
              ? 'did you mean "$suggestion"?'
              : modelNames.isEmpty
                  ? 'declare a model with that name first'
                  : 'declared models: ${modelNames.join(", ")}',
        ));
      }

      String? onDelete = _readReferentialAction(
        valueNode.nodes['on_delete'],
        keyName: 'on_delete',
      );
      String? onUpdate = _readReferentialAction(
        valueNode.nodes['on_update'],
        keyName: 'on_update',
      );

      relationship = RelationshipConfig(
        references: referencesValue,
        reverseName: _parseReverseName(modelName, columnName, valueNode),
        isManyToMany: isM2M,
        onDelete: onDelete,
        onUpdate: onUpdate,
      );
    } else {
      // Unknown / typo'd type that doesn't look like a model name.
      final suggestion = suggestClosest(typeValue, _builtinTypeStrings);
      _errors.add(SchemaError(
        code: 'unknown_type',
        message: 'unknown column type "$typeValue"',
        span: typeNode.span,
        hint: suggestion != null
            ? 'did you mean "$suggestion"?'
            : 'expected one of: ${_builtinTypeStrings.join(", ")}, '
                'or a model name (e.g. `User`)',
      ));
      return null;
    }

    if (constraints.isPrimary && constraints.isNull) {
      _errors.add(SchemaError(
        code: 'invalid_primary_key',
        message:
            '"$modelName.$columnName" is `is_primary: true` but also `is_null: true`',
        span: valueNode.nodes['is_null']?.span ?? keyNode.span,
        hint: 'a primary key cannot be NULL — set `is_null: false`',
      ));
    }
    if (relationship != null && constraints.isPrimary) {
      _errors.add(SchemaError(
        code: 'invalid_primary_key',
        message:
            'relationship column "$modelName.$columnName" cannot be `is_primary`',
        span: keyNode.span,
        hint:
            'declare a separate `id` column or use a non-relation primary key',
      ));
    }

    return ColumnDefinition(
      name: columnName,
      type: type,
      constraints: constraints,
      relationship: relationship,
      vector: vectorConfig,
      array: arrayConfig,
      enumConfig: enumConfig,
      checkExpression: checkExpression,
    );
  }

  String? _readReferentialAction(YamlNode? node, {required String keyName}) {
    if (node == null) return null;
    final v = node.value;
    if (v is String) {
      final upper = v.toUpperCase().trim();
      if (_validReferentialActions.contains(upper)) return upper;
      final suggestion = suggestClosest(upper, _validReferentialActions);
      _errors.add(SchemaError(
        code: 'invalid_referential_action',
        message:
            '`$keyName` must be one of: ${_validReferentialActions.join(", ")}',
        span: node.span,
        hint: suggestion != null ? 'did you mean "$suggestion"?' : null,
      ));
      return null;
    }
    _errors.add(SchemaError(
      code: 'invalid_referential_action',
      message: '`$keyName` must be a string',
      span: node.span,
    ));
    return null;
  }

  String? _parseReverseName(
    String modelName,
    String columnName,
    YamlMap valueNode,
  ) {
    final reverseNameNode = valueNode.nodes['reverse_name'];
    if (reverseNameNode == null) return null;
    final v = reverseNameNode.value;
    if (v is String && _identifierPattern.hasMatch(v)) {
      return v;
    }
    _errors.add(SchemaError(
      code: 'invalid_reverse_name',
      message:
          '`reverse_name` on "$modelName.$columnName" must be a snake_case identifier',
      span: reverseNameNode.span,
    ));
    return null;
  }

  ColumnConstraints _parseConstraints(
    String modelName,
    String columnName,
    YamlMap node, {
    String? columnTypeHint,
  }) {
    bool readBool(String key, bool def) {
      final n = node.nodes[key];
      if (n == null) return def;
      final v = n.value;
      if (v is bool) return v;
      _errors.add(SchemaError(
        code: 'invalid_value',
        message:
            '`$key` on "$modelName.$columnName" must be a boolean (true or false)',
        span: n.span,
        hint: 'change to `$key: ${def ? "true" : "false"}` (the default)',
      ));
      return def;
    }

    final defaultNode = node.nodes['default'];
    dynamic defaultValue = defaultNode?.value;
    if (defaultNode != null &&
        defaultValue is! String &&
        defaultValue is! num &&
        defaultValue is! bool &&
        defaultValue != null) {
      _errors.add(SchemaError(
        code: 'invalid_value',
        message:
            '`default` on "$modelName.$columnName" must be a string, number, boolean, or null',
        span: defaultNode.span,
      ));
      defaultValue = null;
    }

    int? maxLength;
    final maxLengthNode = node.nodes['max_length'];
    if (maxLengthNode != null) {
      final v = maxLengthNode.value;
      if (v is int && v > 0) {
        maxLength = v;
        if (columnTypeHint != null &&
            columnTypeHint != 'varchar' &&
            !_foreignKeyTypeAliases.contains(columnTypeHint)) {
          _errors.add(SchemaError(
            code: 'invalid_max_length',
            message: '`max_length` is only valid on `type: varchar` '
                '("$modelName.$columnName" is "$columnTypeHint")',
            span: maxLengthNode.span,
          ));
          maxLength = null;
        }
      } else {
        _errors.add(SchemaError(
          code: 'invalid_max_length',
          message: '`max_length` on "$modelName.$columnName" must be a '
              'positive integer',
          span: maxLengthNode.span,
        ));
      }
    }

    return ColumnConstraints(
      isNull: readBool('is_null', true),
      isUnique: readBool('is_unique', false),
      isIndex: readBool('is_index', false),
      isPrimary: readBool('is_primary', false),
      allowBlank: readBool('allow_blank', true),
      defaultValue: defaultValue,
      maxLength: maxLength,
    );
  }

  IndexDefinition? _parseIndex({
    required String modelName,
    required String indexName,
    required YamlNode valueNode,
    required List<ColumnDefinition> columns,
  }) {
    if (valueNode is! YamlMap) {
      _errors.add(SchemaError(
        code: 'expected_map',
        message: 'index "$indexName" must be a map with `columns: [...]`',
        span: valueNode.span,
      ));
      return null;
    }

    _checkUnknownKeys(
      ownerLabel: 'index "$modelName.$indexName"',
      mapNode: valueNode,
      knownKeys: _knownIndexKeys,
    );

    final columnsNode = valueNode.nodes['columns'];
    if (columnsNode == null) {
      _errors.add(SchemaError(
        code: 'missing_columns',
        message: 'index "$indexName" is missing required `columns:` list',
        span: valueNode.span,
        hint: 'add e.g. `columns: [first_name, last_name]`',
      ));
      return null;
    }
    if (columnsNode is! YamlList) {
      _errors.add(SchemaError(
        code: 'expected_list',
        message:
            '`columns` of index "$indexName" must be a list of column names',
        span: columnsNode.span,
      ));
      return null;
    }

    final modelColumnNames = columns.map((c) => c.name).toSet();
    final colNames = <String>[];
    for (final entryNode in columnsNode.nodes) {
      final v = entryNode.value;
      if (v is! String) {
        _errors.add(SchemaError(
          code: 'invalid_value',
          message: 'index column entry must be a string',
          span: entryNode.span,
        ));
        continue;
      }
      if (!modelColumnNames.contains(v)) {
        final suggestion = suggestClosest(v, modelColumnNames);
        _errors.add(SchemaError(
          code: 'unknown_column',
          message: 'index "$indexName" references unknown column "$v"',
          span: entryNode.span,
          hint: suggestion != null
              ? 'did you mean "$suggestion"?'
              : modelColumnNames.isEmpty
                  ? 'this model declares no columns'
                  : 'declared columns: ${modelColumnNames.join(", ")}',
        ));
        continue;
      }
      colNames.add(v);
    }

    var unique = false;
    final uniqueNode = valueNode.nodes['unique'];
    if (uniqueNode != null) {
      final v = uniqueNode.value;
      if (v is bool) {
        unique = v;
      } else {
        _errors.add(SchemaError(
          code: 'invalid_value',
          message: '`unique` on index "$indexName" must be true or false',
          span: uniqueNode.span,
        ));
      }
    }

    // pgvector index extras.
    VectorIndexMethod? using;
    final usingNode = valueNode.nodes['using'];
    if (usingNode != null) {
      final v = usingNode.value;
      final parsed = v is String ? VectorIndexMethod.fromAlias(v) : null;
      if (parsed == null) {
        final allowed = VectorIndexMethod.values.map((e) => e.name).join(', ');
        _errors.add(SchemaError(
          code: 'invalid_index_method',
          message: '`using` on index "$indexName" must be one of: $allowed',
          span: usingNode.span,
        ));
      } else {
        using = parsed;
      }
    }

    VectorDistance? distance;
    final distanceNode = valueNode.nodes['distance'];
    if (distanceNode != null) {
      final v = distanceNode.value;
      final parsed = v is String ? VectorDistance.fromAlias(v) : null;
      if (parsed == null) {
        final allowed = VectorDistance.values.map((e) => e.alias).join(', ');
        _errors.add(SchemaError(
          code: 'invalid_distance',
          message: '`distance` on index "$indexName" must be one of: $allowed',
          span: distanceNode.span,
        ));
      } else {
        distance = parsed;
      }
    }

    if (unique && using != null) {
      _errors.add(SchemaError(
        code: 'invalid_vector_index',
        message: 'pgvector index "$indexName" cannot be `unique: true`',
        span: uniqueNode!.span,
      ));
      unique = false;
    }

    return IndexDefinition(
      name: indexName,
      columns: colNames,
      isUnique: unique,
      using: using,
      distance: distance,
    );
  }

  /// Cross-model invariants that need every model parsed first.
  void _crossValidate(List<ModelDefinition> models, YamlMap root) {
    // Build a map of model -> declared field names so we can spot
    // reverse_name collisions on the *target* side.
    final modelByName = {for (final m in models) m.name: m};

    // Track reverse_name -> (target model, source model.column) so we
    // can detect two relationships colliding on the same accessor.
    final reverseSeen = <String, Map<String, String>>{};

    for (final model in models) {
      final modelNode = root.nodes[model.name];
      if (modelNode is! YamlMap) continue;
      final columnsNode = modelNode.nodes['columns'];
      if (columnsNode is! YamlMap) continue;

      for (final col in model.columns) {
        final rel = col.relationship;
        if (rel == null) continue;
        final reverseName = rel.reverseName;
        if (reverseName == null) continue;

        final colNode = columnsNode.nodes[col.name];
        final span = colNode is YamlMap
            ? colNode.nodes['reverse_name']?.span ?? colNode.span
            : colNode?.span;
        if (span == null) continue;

        // Collision with a column on the target model:
        final target = modelByName[rel.references];
        if (target != null &&
            target.columns.any((c) => c.name == reverseName)) {
          _errors.add(SchemaError(
            code: 'reverse_name_collision',
            message:
                '`reverse_name: $reverseName` collides with existing column '
                '"${target.name}.$reverseName"',
            span: span,
            hint: 'pick a different `reverse_name` to avoid shadowing',
          ));
        }

        // Collision with another relation pointing at the same target:
        final byTarget = reverseSeen.putIfAbsent(rel.references!, () => {});
        if (byTarget.containsKey(reverseName)) {
          _errors.add(SchemaError(
            code: 'reverse_name_collision',
            message:
                'two relationships define `reverse_name: $reverseName` on "${rel.references}"',
            span: span,
            notes: ['first defined at "${byTarget[reverseName]}"'],
          ));
        } else {
          byTarget[reverseName] = '${model.name}.${col.name}';
        }
      }
    }
  }

  void _checkUnknownKeys({
    required String ownerLabel,
    required YamlMap mapNode,
    required Set<String> knownKeys,
  }) {
    for (final keyEntry in mapNode.nodes.keys) {
      final keyNode = keyEntry as YamlNode;
      final keyStr = keyNode.value;
      if (keyStr is! String) {
        _errors.add(SchemaError(
          code: 'invalid_key',
          message: 'keys on $ownerLabel must be strings',
          span: keyNode.span,
        ));
        continue;
      }
      if (knownKeys.contains(keyStr)) continue;
      final suggestion = suggestClosest(keyStr, knownKeys);
      _errors.add(SchemaError(
        code: 'unknown_key',
        message: 'unknown key "$keyStr" on $ownerLabel',
        span: keyNode.span,
        hint: suggestion != null
            ? 'did you mean "$suggestion"?'
            : 'expected one of: ${knownKeys.join(", ")}',
      ));
    }
  }

  SourceSpan _wholeFileSpan() {
    final file = SourceFile.fromString(_content, url: _sourceUrl);
    return file.span(0, _content.isEmpty ? 0 : _content.length);
  }
}

bool _isPascalCaseLike(String s) {
  if (s.isEmpty) return false;
  if (!_identifierPattern.hasMatch(s)) return false;
  return s[0] == s[0].toUpperCase() && s[0] != s[0].toLowerCase();
}

ColumnType? _builtinFromString(String typeStr) {
  switch (typeStr.toLowerCase()) {
    case 'varchar':
      return ColumnType.varchar;
    case 'text':
      return ColumnType.text;
    case 'integer':
      return ColumnType.integer;
    case 'bigint':
      return ColumnType.bigint;
    case 'boolean':
      return ColumnType.boolean;
    case 'date':
      return ColumnType.date;
    case 'timestamp':
      return ColumnType.timestamp;
    case 'decimal':
      return ColumnType.decimal;
    case 'json':
      return ColumnType.json;
    case 'uuid':
      return ColumnType.uuid;
    case 'vector':
      return ColumnType.vector;
    case 'point':
      return ColumnType.point;
    case 'box':
      return ColumnType.box;
    case 'circle':
      return ColumnType.circle;
    case 'lseg':
      return ColumnType.lseg;
  }
  return null;
}

String _toSnakeCase(String input) {
  return input
      .replaceAllMapped(
          RegExp(r'[A-Z]'), (match) => '_${match.group(0)?.toLowerCase()}')
      .replaceFirst(RegExp(r'^_'), '');
}

/// Pluralise a snake_case identifier using basic English rules.
/// Used to derive the default SQL table name from a model name so that:
///   - the common convention of plural table names is followed
///   - reserved SQL keywords like `user` and `order` are avoided
///     (they become `users` and `orders`).
String _pluralSnakeCase(String snake) {
  if (snake.endsWith('s') ||
      snake.endsWith('x') ||
      snake.endsWith('z') ||
      snake.endsWith('ch') ||
      snake.endsWith('sh')) {
    return '${snake}es';
  }
  if (snake.endsWith('y') &&
      snake.length > 1 &&
      !'aeiou'.contains(snake[snake.length - 2])) {
    return '${snake.substring(0, snake.length - 1)}ies';
  }
  return '${snake}s';
}

/// PostgreSQL reserved words that are unsafe as unquoted table names.
/// Even when quoted the names cause confusion; the generator warns when
/// a derived table name matches one of these.
const _pgReservedWords = {
  'user',
  'order',
  'like',
  'table',
  'column',
  'index',
  'group',
  'select',
  'insert',
  'update',
  'delete',
  'from',
  'where',
  'join',
  'primary',
  'foreign',
  'key',
  'default',
  'check',
  'unique',
  'constraint',
  'trigger',
  'view',
  'sequence',
  'schema',
  'database',
  'all',
  'and',
  'any',
  'as',
  'asc',
  'between',
  'by',
  'case',
  'cast',
  'create',
  'cross',
  'current_date',
  'current_time',
  'current_timestamp',
  'desc',
  'distinct',
  'drop',
  'else',
  'end',
  'except',
  'exists',
  'false',
  'for',
  'full',
  'grant',
  'having',
  'in',
  'inner',
  'intersect',
  'into',
  'is',
  'left',
  'limit',
  'natural',
  'not',
  'null',
  'offset',
  'on',
  'or',
  'outer',
  'right',
  'set',
  'then',
  'to',
  'true',
  'union',
  'values',
  'when',
  'with',
};
