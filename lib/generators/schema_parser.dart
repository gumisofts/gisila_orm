/// Schema parser & validator for Gisila ORM.
///
/// Loads a `*.gisila.yaml` document with full source-span tracking
/// and produces a [SchemaDefinition]. Every shape mistake the user
/// can make in the YAML is reported as a [SchemaError] tied to the
/// exact line/column of the offending token; the parser collects
/// them all and then throws a single [SchemaValidationException].
library gisila.generators.schema_parser;

import 'dart:io';

import 'package:gisila/generators/schema_errors.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

export 'package:gisila/generators/schema_errors.dart'
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
  // Reference types
  foreignKey,
  manyToMany,
}

/// Column constraint configuration
class ColumnConstraints {
  final bool isNull;
  final bool isUnique;
  final bool isIndex;
  final bool isPrimary;
  final bool allowBlank;
  final dynamic defaultValue;

  const ColumnConstraints({
    this.isNull = true,
    this.isUnique = false,
    this.isIndex = false,
    this.isPrimary = false,
    this.allowBlank = true,
    this.defaultValue,
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

/// Column definition
class ColumnDefinition {
  final String name;
  final ColumnType type;
  final ColumnConstraints constraints;
  final RelationshipConfig? relationship;

  const ColumnDefinition({
    required this.name,
    required this.type,
    required this.constraints,
    this.relationship,
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
        return 'VARCHAR(255)';
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
      case ColumnType.foreignKey:
        return 'INTEGER';
      case ColumnType.manyToMany:
        return ''; // Handled by junction table
    }
  }

  bool get isRelationship =>
      type == ColumnType.foreignKey || type == ColumnType.manyToMany;
}

/// Index definition
class IndexDefinition {
  final String name;
  final List<String> columns;
  final bool isUnique;

  const IndexDefinition({
    required this.name,
    required this.columns,
    this.isUnique = false,
  });
}

/// Model definition
class ModelDefinition {
  final String name;
  final String tableName;
  final List<ColumnDefinition> columns;
  final List<IndexDefinition> indexes;

  const ModelDefinition({
    required this.name,
    required this.tableName,
    required this.columns,
    this.indexes = const [],
  });

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
  final Map<String, ModelDefinition> _modelMap = {};

  SchemaDefinition({required this.models}) {
    for (final model in models) {
      _modelMap[model.name] = model;
    }
  }

  /// Get model by name
  ModelDefinition? getModel(String name) => _modelMap[name];

  /// Get all model names
  List<String> get modelNames => models.map((m) => m.name).toList();

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
  factory SchemaDefinition.fromYaml(String yamlContent, {Uri? sourceUrl}) {
    final parser = _SchemaParser(yamlContent, sourceUrl);
    return parser.parse();
  }

  static Future<SchemaDefinition> fromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Schema file not found: $filePath');
    }

    final content = await file.readAsString();
    return SchemaDefinition.fromYaml(content, sourceUrl: file.uri);
  }
}

/// Relationship information between models
class RelationshipInfo {
  final String fromModel;
  final String toModel;
  final String fromColumn;
  final String? reverseName;
  final bool isManyToMany;

  const RelationshipInfo({
    required this.fromModel,
    required this.toModel,
    required this.fromColumn,
    this.reverseName,
    this.isManyToMany = false,
  });

  String get junctionTableName =>
      isManyToMany ? '${_toSnakeCase(fromModel)}_${_toSnakeCase(toModel)}' : '';
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
};

const _knownModelKeys = <String>{'columns', 'indexes', 'db_table'};

const _knownColumnKeys = <String>{
  'type',
  'is_null',
  'is_unique',
  'is_index',
  'is_primary',
  'allow_blank',
  'default',
  'references',
  'reverse_name',
  'many_to_many',
  'on_delete',
  'on_update',
};

const _knownIndexKeys = <String>{'columns', 'unique'};

const _validReferentialActions = <String>{
  'NO ACTION',
  'RESTRICT',
  'CASCADE',
  'SET NULL',
  'SET DEFAULT',
};

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Internal parser that walks a [YamlNode] tree, accumulates
/// [SchemaError]s, and finally builds a [SchemaDefinition] (or throws
/// [SchemaValidationException] if anything went wrong).
class _SchemaParser {
  _SchemaParser(this._content, this._sourceUrl);

  final String _content;
  final Uri? _sourceUrl;
  final List<SchemaError> _errors = [];

  SchemaDefinition parse() {
    final root = _loadRoot();
    if (root == null) {
      throw SchemaValidationException(_errors);
    }

    final modelNames = _collectModelNames(root);

    final models = <ModelDefinition>[];
    final seen = <String, SourceSpan>{};
    for (final entry in root.nodes.entries) {
      final keyNode = entry.key as YamlNode;
      final modelNameValue = keyNode.value;
      if (modelNameValue is! String || modelNameValue.isEmpty) {
        // Already reported by _collectModelNames.
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

      final model =
          _parseModel(modelNameValue, keyNode, entry.value, modelNames);
      if (model != null) models.add(model);
    }

    _crossValidate(models, root);

    if (_errors.isNotEmpty) throw SchemaValidationException(_errors);
    return SchemaDefinition(models: models);
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

  ModelDefinition? _parseModel(
    String modelName,
    YamlNode keyNode,
    YamlNode valueNode,
    Set<String> modelNames,
  ) {
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

    // db_table
    String tableName = _toSnakeCase(modelName);
    final dbTableNode = valueNode.nodes['db_table'];
    if (dbTableNode != null) {
      final v = dbTableNode.value;
      if (v is String && v.isNotEmpty && _identifierPattern.hasMatch(v)) {
        tableName = v;
      } else {
        _errors.add(SchemaError(
          code: 'invalid_db_table',
          message:
              '`db_table` of "$modelName" must be a non-empty SQL identifier',
          span: dbTableNode.span,
          hint: 'use snake_case letters, digits, and underscores only',
        ));
      }
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
      if (!_identifierPattern.hasMatch(colNameValue)) {
        _errors.add(SchemaError(
          code: 'invalid_column_name',
          message: 'invalid column name "$colNameValue"',
          span: colKey.span,
          hint: 'use snake_case letters, digits, and underscores only',
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

    return ModelDefinition(
      name: modelName,
      tableName: tableName,
      columns: columns,
      indexes: indexes,
    );
  }

  ColumnDefinition? _parseColumn({
    required String modelName,
    required String columnName,
    required YamlNode keyNode,
    required YamlNode valueNode,
    required Set<String> modelNames,
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

    final isBuiltin = _builtinTypeStrings.contains(typeValue.toLowerCase());
    final referencesNode = valueNode.nodes['references'];
    final manyToManyNode = valueNode.nodes['many_to_many'];
    final isM2M = manyToManyNode?.value == true;
    final hasReferences = referencesNode != null;
    final looksLikeModel = !isBuiltin && _isPascalCaseLike(typeValue);

    // Validate constraints unconditionally so the user sees every
    // mistake (bad bool, bad default, ...) on this column in one
    // shot, even when the `type:` is itself invalid.
    final constraints = _parseConstraints(modelName, columnName, valueNode);

    ColumnType type;
    RelationshipConfig? relationship;

    if (isBuiltin) {
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

      String? reverseName;
      final reverseNameNode = valueNode.nodes['reverse_name'];
      if (reverseNameNode != null) {
        final v = reverseNameNode.value;
        if (v is String && _identifierPattern.hasMatch(v)) {
          reverseName = v;
        } else {
          _errors.add(SchemaError(
            code: 'invalid_reverse_name',
            message:
                '`reverse_name` on "$modelName.$columnName" must be a snake_case identifier',
            span: reverseNameNode.span,
          ));
        }
      }

      relationship = RelationshipConfig(
        references: referencesValue,
        reverseName: reverseName,
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

  ColumnConstraints _parseConstraints(
    String modelName,
    String columnName,
    YamlMap node,
  ) {
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

    return ColumnConstraints(
      isNull: readBool('is_null', true),
      isUnique: readBool('is_unique', false),
      isIndex: readBool('is_index', false),
      isPrimary: readBool('is_primary', false),
      allowBlank: readBool('allow_blank', true),
      defaultValue: defaultValue,
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

    return IndexDefinition(
      name: indexName,
      columns: colNames,
      isUnique: unique,
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
  }
  return null;
}

String _toSnakeCase(String input) {
  return input
      .replaceAllMapped(
          RegExp(r'[A-Z]'), (match) => '_${match.group(0)?.toLowerCase()}')
      .replaceFirst(RegExp(r'^_'), '');
}
