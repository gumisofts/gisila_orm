/// Emit Dart `*.g.dart` source for a parsed [SchemaDefinition].
///
/// The output for each model `User` contains:
///
///  * `class User` with `final` fields, a generative constructor,
///    `User.fromRow(Map)` / `toRow()`, `User.fromJson` / `toJson`,
///    `copyWith`, plus static `Relation` references (e.g. `User.posts`).
///  * `class UserTable` with `static const` typed [ColumnRef]s and a
///    `static const TableMeta<User>`.
///  * `Query<User> get UsersQ => Query<User>(UserTable.metadata);` -
///    convenience entry point.
library gisila.generators.codegen.dart_emitter;

import 'package:gisila_orm/generators/schema_parser.dart';

/// Emit the full `.g.dart` content for [schema].
String emitDart(SchemaDefinition schema) {
  final buf = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln('// Source: gisila build_runner schema generator.')
    ..writeln()
    ..writeln('// ignore_for_file: type=lint, unused_import')
    ..writeln()
    ..writeln("import 'package:gisila_orm/gisila.dart';")
    ..writeln();

  for (final e in schema.enums) {
    buf.writeln(_emitEnum(e));
    buf.writeln();
  }

  for (final model in schema.models) {
    buf
      ..writeln(_emitModelClass(model, schema))
      ..writeln()
      ..writeln(_emitTableClass(model, schema))
      ..writeln()
      ..writeln(_emitQueryAccessor(model))
      ..writeln();
  }

  return buf.toString();
}

String _emitEnum(EnumDefinition e) {
  final buf = StringBuffer()
    ..writeln('enum ${e.name} {')
    ..writeln('  ${e.values.join(',\n  ')},')
    ..writeln('}')
    ..writeln()
    ..writeln('extension ${e.name}Gisila on ${e.name} {')
    ..writeln('  /// Postgres ENUM label for this value.')
    ..writeln('  String get sqlValue => name;')
    ..writeln()
    ..writeln('  static ${e.name} parse(String raw) {')
    ..writeln('    for (final v in ${e.name}.values) {')
    ..writeln('      if (v.name == raw) return v;')
    ..writeln('    }')
    ..writeln(
        "    throw FormatException('Unknown ${e.name} value: \$raw');")
    ..writeln('  }')
    ..writeln('}');
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Model class
// ---------------------------------------------------------------------------

String _emitModelClass(ModelDefinition model, SchemaDefinition schema) {
  final fields =
      model.columns.where((c) => c.type != ColumnType.manyToMany).toList();
  final m2mFields = model.manyToManyColumns;
  final buf = StringBuffer()..writeln('class ${model.name} with Preloadable {');

  // Fields ----------------------------------------------------------------
  for (final col in fields) {
    if (col.type == ColumnType.foreignKey) {
      final idType = _dartTypeFor(_fkTargetColumn(col, schema));
      buf.writeln('  final $idType ${col.dartFieldName};');
    } else {
      buf.writeln('  final ${_dartTypeFor(col)} ${col.dartFieldName};');
    }
  }

  // Constructor -----------------------------------------------------------
  // Note: not `const` because the model mixes in `Preloadable`, which
  // owns a mutable storage map. The cost is negligible at runtime and
  // it keeps the eager-loading API shape clean.
  buf.writeln();
  buf.writeln('  ${model.name}({');
  for (final col in fields) {
    final required = !col.constraints.isNull && !col.constraints.isPrimary;
    final keyword = required ? 'required ' : '';
    buf.writeln('    ${keyword}this.${col.dartFieldName},');
  }
  buf.writeln('  });');

  // fromRow ---------------------------------------------------------------
  buf
    ..writeln()
    ..writeln('  factory ${model.name}.fromRow(Map<String, dynamic> row) =>')
    ..writeln('      ${model.name}(');
  for (final col in fields) {
    final dbName = col.physicalColumnName;
    final dartName = col.dartFieldName;
    final coerceCol =
        col.type == ColumnType.foreignKey ? _fkTargetColumn(col, schema) : col;
    final coercion =
        _coerce("row['$dbName']", coerceCol, primaryKeyNullable: true);
    buf.writeln('        $dartName: $coercion,');
  }
  buf.writeln('      );');

  // toRow -----------------------------------------------------------------
  buf
    ..writeln()
    ..writeln('  Map<String, dynamic> toRow() => {');
  for (final col in fields) {
    final dbName = col.physicalColumnName;
    final dartName = col.dartFieldName;
    final encoded = _encode(dartName, col);
    buf.writeln("        '$dbName': $encoded,");
  }
  buf.writeln('      };');

  // fromJson/toJson aliases ----------------------------------------------
  buf
    ..writeln()
    ..writeln('  factory ${model.name}.fromJson(Map<String, dynamic> json) =>')
    ..writeln('      ${model.name}.fromRow(json);')
    ..writeln()
    ..writeln(
        '  Map<String, dynamic> toJson({List<String> exclude = const [], List<String> only = const []}) {')
    ..writeln('    final row = toRow();')
    ..writeln(
        '    if (only.isNotEmpty) return {for (final k in only) k: row[k]};')
    ..writeln('    if (exclude.isEmpty) return row;')
    ..writeln(
        '    return Map.of(row)..removeWhere((k, _) => exclude.contains(k));')
    ..writeln('  }');

  // copyWith --------------------------------------------------------------
  buf
    ..writeln()
    ..writeln('  ${model.name} copyWith({');
  for (final col in fields) {
    final base = col.type == ColumnType.foreignKey
        ? _baseDartType(_fkTargetColumn(col, schema))
        : _dartTypeFor(col);
    final type = base.endsWith('?') ? base : '$base?';
    final name = col.dartFieldName;
    buf.writeln('    $type $name,');
  }
  buf.writeln('  }) =>');
  buf.writeln('      ${model.name}(');
  for (final col in fields) {
    final name = col.dartFieldName;
    buf.writeln('        $name: $name ?? this.$name,');
  }
  buf.writeln('      );');

  // validate --------------------------------------------------------------
  // Model-side checks for `allow_blank: false` on string columns.
  final blankChecked = fields
      .where((c) =>
          !c.constraints.allowBlank &&
          (c.type == ColumnType.varchar ||
              c.type == ColumnType.text ||
              c.type == ColumnType.uuid))
      .toList();
  buf
    ..writeln()
    ..writeln('  /// Returns validation errors for this instance.')
    ..writeln('  ///')
    ..writeln(
        '  /// Currently checks `allow_blank: false` string columns; empty')
    ..writeln('  /// when every such field is non-blank (or null).')
    ..writeln('  List<String> validate() {')
    ..writeln('    final errors = <String>[];');
  for (final col in blankChecked) {
    final name = col.dartFieldName;
    final nullable = col.constraints.isNull || col.constraints.isPrimary;
    if (nullable) {
      buf
        ..writeln('    {')
        ..writeln('      final value = $name;')
        ..writeln('      if (value != null && value.trim().isEmpty) {')
        ..writeln(
            "        errors.add('${model.name}.$name must not be blank');")
        ..writeln('      }')
        ..writeln('    }');
    } else {
      buf
        ..writeln('    if ($name.trim().isEmpty) {')
        ..writeln(
            "      errors.add('${model.name}.$name must not be blank');")
        ..writeln('    }');
    }
  }
  buf
    ..writeln('    return errors;')
    ..writeln('  }');

  // Static relations ------------------------------------------------------
  // Forward relations declared on this model (belongs-to + many-to-many).
  final relationDescriptors = <_RelationEmit>[];

  for (final col in model.foreignKeyColumns) {
    final ref = col.relationship!.references!;
    final fkColumn = col.physicalColumnName;
    // Relation accessor uses the logical YAML name (author → author),
    // not the physical FK field (authorId).
    final relName = _camel(col.name.endsWith('_id')
        ? col.name.substring(0, col.name.length - 3)
        : col.name);
    final relAccessor = relName.isEmpty ? _camel(col.name) : relName;
    buf
      ..writeln()
      ..writeln(
          '  static final Relation<${model.name}, $ref> $relAccessor =')
      ..writeln('      BelongsToRelation<${model.name}, $ref>(')
      ..writeln("        parentTable: '${model.tableName}',")
      ..writeln("        childTable: '${_tableOf(ref, schema)}',")
      ..writeln("        name: '$relAccessor',")
      ..writeln("        parentForeignKey: '$fkColumn',")
      ..writeln('        childMeta: ${ref}Table.metadata,')
      ..writeln('      );');
    relationDescriptors.add(_RelationEmit(
      kind: RelationKind.belongsTo,
      childType: ref,
      relationName: relAccessor,
    ));
  }

  for (final col in m2mFields) {
    final ref = col.relationship!.references!;
    final junction = _junction(model.name, ref, schema);
    final relName = _camel(col.name);
    buf
      ..writeln()
      ..writeln('  static final Relation<${model.name}, $ref> $relName =')
      ..writeln('      ManyToManyRelation<${model.name}, $ref>(')
      ..writeln("        parentTable: '${model.tableName}',")
      ..writeln("        childTable: '${_tableOf(ref, schema)}',")
      ..writeln("        name: '$relName',")
      ..writeln("        junctionTable: '$junction',")
      ..writeln("        junctionParentKey: '${_snake(model.name)}_id',")
      ..writeln("        junctionChildKey: '${_snake(ref)}_id',")
      ..writeln('        childMeta: ${ref}Table.metadata,')
      ..writeln('      );');
    relationDescriptors.add(_RelationEmit(
      kind: RelationKind.manyToMany,
      childType: ref,
      relationName: relName,
    ));
  }

  // Inverse relations - reverse-side of belongs-to / many-to-many
  // declared on other models pointing at this one.
  for (final inverse in _inversesFor(model, schema)) {
    final reverseName = inverse.reverseName!;
    final relName = _camel(reverseName);
    if (inverse.isManyToMany) {
      // Inverse of a M2M is also a M2M, just with the junction read in
      // the other direction.
      final junction = _junction(inverse.fromModel, inverse.toModel, schema);
      buf
        ..writeln()
        ..writeln(
            '  static final Relation<${model.name}, ${inverse.fromModel}> '
            '$relName =')
        ..writeln(
            '      ManyToManyRelation<${model.name}, ${inverse.fromModel}>(')
        ..writeln("        parentTable: '${model.tableName}',")
        ..writeln(
            "        childTable: '${_tableOf(inverse.fromModel, schema)}',")
        ..writeln("        name: '$relName',")
        ..writeln("        junctionTable: '$junction',")
        ..writeln("        junctionParentKey: '${_snake(model.name)}_id',")
        ..writeln(
            "        junctionChildKey: '${_snake(inverse.fromModel)}_id',")
        ..writeln('        childMeta: ${inverse.fromModel}Table.metadata,')
        ..writeln('      );');
      relationDescriptors.add(_RelationEmit(
        kind: RelationKind.manyToMany,
        childType: inverse.fromModel,
        relationName: relName,
      ));
    } else {
      final fkColumn = inverse.physicalFromColumn;
      final useHasOne = inverse.isUnique;
      final relationClass =
          useHasOne ? 'HasOneRelation' : 'HasManyRelation';
      final kind =
          useHasOne ? RelationKind.hasOne : RelationKind.hasMany;
      buf
        ..writeln()
        ..writeln(
            '  static final Relation<${model.name}, ${inverse.fromModel}> '
            '$relName =')
        ..writeln(
            '      $relationClass<${model.name}, ${inverse.fromModel}>(')
        ..writeln("        parentTable: '${model.tableName}',")
        ..writeln(
            "        childTable: '${_tableOf(inverse.fromModel, schema)}',")
        ..writeln("        name: '$relName',")
        ..writeln("        childForeignKey: '$fkColumn',")
        ..writeln('        childMeta: ${inverse.fromModel}Table.metadata,')
        ..writeln('      );');
      relationDescriptors.add(_RelationEmit(
        kind: kind,
        childType: inverse.fromModel,
        relationName: relName,
      ));
    }
  }

  // Typed accessors for preloaded relations.
  for (final r in relationDescriptors) {
    buf.writeln();
    final isCollection =
        r.kind == RelationKind.hasMany || r.kind == RelationKind.manyToMany;
    if (isCollection) {
      buf
        ..writeln(
            '  /// Preloaded ${r.relationName}; empty list when not preloaded.')
        ..writeln('  List<${r.childType}> get ${r.relationName}List =>')
        ..writeln(
            "      preloaded<List<${r.childType}>>('${r.relationName}') ?? const [];");
    } else {
      buf
        ..writeln(
            '  /// Preloaded ${r.relationName}; null when not preloaded or absent.')
        ..writeln('  ${r.childType}? get ${r.relationName}Loaded =>')
        ..writeln("      preloaded<${r.childType}>('${r.relationName}');");
    }
  }

  buf.writeln('}');
  return buf.toString();
}

/// Internal record used for emitting typed accessors in a second pass
/// after the static relations have been written.
class _RelationEmit {
  final RelationKind kind;
  final String childType;
  final String relationName;
  const _RelationEmit({
    required this.kind,
    required this.childType,
    required this.relationName,
  });
}

enum RelationKind { hasMany, hasOne, belongsTo, manyToMany }

// ---------------------------------------------------------------------------
// Table metadata + ColumnRefs
// ---------------------------------------------------------------------------

String _emitTableClass(ModelDefinition model, SchemaDefinition schema) {
  final buf = StringBuffer()
    ..writeln('class ${model.name}Table {')
    ..writeln('  ${model.name}Table._();');

  for (final col in model.columns) {
    if (col.type == ColumnType.manyToMany) continue;
    final dartType = col.type == ColumnType.foreignKey
        ? _dartTypeFor(_fkTargetColumn(col, schema))
        : _dartTypeFor(col);
    final dbColumn = col.physicalColumnName;
    final fieldName = col.dartFieldName;
    buf.writeln(
      '  static const ColumnRef<$dartType> $fieldName = ColumnRef<$dartType>(',
    );
    buf
      ..writeln("    table: '${model.tableName}',")
      ..writeln("    column: '$dbColumn',")
      ..writeln('  );');
  }

  // TableMeta
  final cols = model.columns
      .where((c) => c.type != ColumnType.manyToMany)
      .map((c) => "'${c.physicalColumnName}'")
      .join(', ');
  final pk = model.primaryKey?.name ?? 'id';
  buf
    ..writeln()
    ..writeln('  static const TableMeta<${model.name}> metadata =')
    ..writeln('      TableMeta<${model.name}>(')
    ..writeln("        tableName: '${model.tableName}',")
    ..writeln("        primaryKey: '$pk',")
    ..writeln('        columnNames: [$cols],')
    ..writeln('        fromRow: ${model.name}.fromRow,')
    ..writeln('      );')
    ..writeln('}');
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Query<T> convenience accessor: e.g. `Users` or `query<User>()`.
// ---------------------------------------------------------------------------

String _emitQueryAccessor(ModelDefinition model) {
  return 'Query<${model.name}> ${_pluralCamel(model.name)}() => '
      'Query<${model.name}>(${model.name}Table.metadata);';
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Find the `(otherModel, fkColumn, reverseName)` triples where some
/// other model references `model` via belongs-to or many-to-many.
List<RelationshipInfo> _inversesFor(
  ModelDefinition model,
  SchemaDefinition schema,
) {
  return [
    for (final r in schema.relationships)
      if (r.toModel == model.name && r.reverseName != null) r,
  ];
}

String _coerce(String expr, ColumnDefinition col,
    {bool primaryKeyNullable = false}) {
  // Callers map foreign-key columns to their target's primary-key type
  // via `_fkTargetColumn` before reaching here, so `col.type` is never
  // `ColumnType.foreignKey` in this function.

  // Primary keys are nullable in the in-memory model (DB-generated on
  // insert), but `fromRow` is only ever called with a real persisted row
  // so the value is non-null in practice.
  final nullable = col.constraints.isNull ||
      (primaryKeyNullable && col.constraints.isPrimary);

  switch (col.type) {
    case ColumnType.timestamp:
    case ColumnType.date:
      if (nullable) {
        return '$expr == null ? null : ($expr is DateTime ? $expr as DateTime : DateTime.parse($expr.toString()))';
      }
      return '$expr is DateTime ? $expr as DateTime : DateTime.parse($expr.toString())';
    case ColumnType.json:
      if (nullable) {
        return '$expr == null ? null : ($expr as Map).cast<String, dynamic>()';
      }
      return '($expr as Map).cast<String, dynamic>()';
    case ColumnType.decimal:
      if (nullable) {
        return '$expr == null ? null : ($expr is num ? ($expr as num).toDouble() : double.parse($expr.toString()))';
      }
      return '$expr is num ? ($expr as num).toDouble() : double.parse($expr.toString())';
    case ColumnType.vector:
      // pgvector usually comes back as text (`[v1,v2,...]`); be lenient
      // and also accept lists of numbers in case the driver decodes it.
      if (nullable) {
        return '$expr == null ? null : ($expr is Vector ? $expr as Vector : '
            '($expr is List ? Vector.fromList(($expr as List).cast<num>()) : '
            'Vector.parse($expr.toString())))';
      }
      return '$expr is Vector ? $expr as Vector : '
          '($expr is List ? Vector.fromList(($expr as List).cast<num>()) : '
          'Vector.parse($expr.toString()))';
    case ColumnType.array:
      final elem = col.array?.elementDartType ?? 'Object';
      final cast = _arrayElementCast(elem);
      if (nullable) {
        return '$expr == null ? null : ($expr is List '
            '? ($expr as List).map((e) => $cast).toList().cast<$elem>() '
            ': <$elem>[])';
      }
      return '$expr is List '
          '? ($expr as List).map((e) => $cast).toList().cast<$elem>() '
          ': <$elem>[]';
    case ColumnType.enumType:
      final name = col.enumConfig!.enumName;
      if (nullable) {
        return '$expr == null ? null : ${name}Gisila.parse($expr.toString())';
      }
      return '${name}Gisila.parse($expr.toString())';
    case ColumnType.point:
      return _geoCoerce(expr, 'Point', nullable);
    case ColumnType.box:
      return _geoCoerce(expr, 'Box', nullable);
    case ColumnType.circle:
      return _geoCoerce(expr, 'Circle', nullable);
    case ColumnType.lseg:
      return _geoCoerce(expr, 'Lseg', nullable);
    default:
      final base = _baseDartType(col);
      return '$expr as $base${nullable ? '?' : ''}';
  }
}

String _arrayElementCast(String elemDart) {
  switch (elemDart) {
    case 'int':
      return '(e is num ? (e as num).toInt() : int.parse(e.toString()))';
    case 'double':
      return '(e is num ? (e as num).toDouble() : double.parse(e.toString()))';
    case 'bool':
      return '(e is bool ? e as bool : e.toString() == \'true\')';
    case 'DateTime':
      return '(e is DateTime ? e as DateTime : DateTime.parse(e.toString()))';
    default:
      return 'e.toString()';
  }
}

String _geoCoerce(String expr, String typeName, bool nullable) {
  if (nullable) {
    return '$expr == null ? null : ($expr is $typeName ? $expr as $typeName : '
        '$typeName.fromString($expr.toString()))';
  }
  return '$expr is $typeName ? $expr as $typeName : '
      '$typeName.fromString($expr.toString())';
}

/// Dart field type honoring nullability and the PK-is-nullable rule.
String _dartTypeFor(ColumnDefinition col) {
  final base = _baseDartType(col);
  final nullable = col.constraints.isNull || col.constraints.isPrimary;
  return nullable && !base.endsWith('?') ? '$base?' : base;
}

/// Strip a trailing `?` if [ColumnDefinition.dartType] added it itself.
String _baseDartType(ColumnDefinition col) {
  final t = col.dartType;
  return t.endsWith('?') ? t.substring(0, t.length - 1) : t;
}

/// The column that governs how a foreign-key column [col] round-trips
/// in Dart: same name/nullability as [col], but the *type* of the
/// referenced model's primary key - so a `uuid` id becomes `String`, a
/// plain integer id becomes `int`, etc. This lets [_dartTypeFor] and
/// [_coerce] handle FK columns without any FK-specific branching.
ColumnDefinition _fkTargetColumn(
    ColumnDefinition col, SchemaDefinition schema) {
  final pk = schema.getModel(col.relationship!.references!)?.primaryKey;
  return ColumnDefinition(
    name: col.name,
    type: pk?.type ?? ColumnType.bigint,
    constraints: col.constraints,
    vector: pk?.vector,
  );
}

String _encode(String fieldName, ColumnDefinition col) {
  switch (col.type) {
    case ColumnType.enumType:
      final nullable = col.constraints.isNull;
      if (nullable) {
        return '$fieldName?.sqlValue';
      }
      return '$fieldName.sqlValue';
    case ColumnType.point:
    case ColumnType.box:
    case ColumnType.circle:
    case ColumnType.lseg:
      final nullable = col.constraints.isNull;
      if (nullable) {
        return '$fieldName?.toSqlLiteral()';
      }
      return '$fieldName.toSqlLiteral()';
    case ColumnType.timestamp:
    case ColumnType.date:
      return fieldName; // postgres driver handles DateTime natively.
    default:
      return fieldName;
  }
}

String _snake(String s) => s
    .replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}')
    .replaceFirst(RegExp(r'^_'), '');

/// Return the SQL table name for [modelName], preferring the resolved
/// [TableMeta.tableName] from the schema over a derived plural-snake name.
/// This ensures that any `db_table:` override in the YAML is honoured.
String _tableOf(String modelName, SchemaDefinition schema) =>
    schema.getModel(modelName)?.tableName ?? _pluralSnake(modelName);

/// Plural snake_case from a PascalCase model name. Mirrors the logic in
/// schema_parser.dart's `_pluralSnakeCase` so the two are always in sync.
String _pluralSnake(String modelName) {
  final s = _snake(modelName);
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

String _camel(String s) {
  final parts = s.split('_');
  if (parts.isEmpty) return s;
  final head = parts.first;
  final tail = parts
      .skip(1)
      .map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1));
  return head + tail.join();
}

String _pluralCamel(String s) {
  // `User` -> `users`, `Author` -> `authors`, `Box` -> `boxes`.
  final base = _snake(s);
  if (base.endsWith('s') ||
      base.endsWith('x') ||
      base.endsWith('z') ||
      base.endsWith('ch') ||
      base.endsWith('sh')) {
    return _camel('${base}es');
  }
  if (base.endsWith('y') &&
      base.length > 1 &&
      !'aeiou'.contains(base[base.length - 2])) {
    return _camel('${base.substring(0, base.length - 1)}ies');
  }
  return _camel('${base}s');
}

String _junction(String a, String b, SchemaDefinition schema) {
  final pair = [_tableOf(a, schema), _tableOf(b, schema)]..sort();
  return pair.join('_');
}
