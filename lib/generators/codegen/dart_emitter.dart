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
      final idType = col.constraints.isNull ? 'int?' : 'int';
      buf.writeln('  final $idType ${_camel(col.name)}Id;');
    } else {
      buf.writeln('  final ${_dartTypeFor(col)} ${_camel(col.name)};');
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
    if (col.type == ColumnType.foreignKey) {
      buf.writeln('    ${keyword}this.${_camel(col.name)}Id,');
    } else {
      buf.writeln('    ${keyword}this.${_camel(col.name)},');
    }
  }
  buf.writeln('  });');

  // fromRow ---------------------------------------------------------------
  buf
    ..writeln()
    ..writeln('  factory ${model.name}.fromRow(Map<String, dynamic> row) =>')
    ..writeln('      ${model.name}(');
  for (final col in fields) {
    final dbName =
        col.type == ColumnType.foreignKey ? "${col.name}_id" : col.name;
    final dartName = col.type == ColumnType.foreignKey
        ? '${_camel(col.name)}Id'
        : _camel(col.name);
    final coercion = _coerce("row['$dbName']", col, primaryKeyNullable: true);
    buf.writeln('        $dartName: $coercion,');
  }
  buf.writeln('      );');

  // toRow -----------------------------------------------------------------
  buf
    ..writeln()
    ..writeln('  Map<String, dynamic> toRow() => {');
  for (final col in fields) {
    final dbName =
        col.type == ColumnType.foreignKey ? "${col.name}_id" : col.name;
    final dartName = col.type == ColumnType.foreignKey
        ? '${_camel(col.name)}Id'
        : _camel(col.name);
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
    ..writeln('  Map<String, dynamic> toJson() => toRow();');

  // copyWith --------------------------------------------------------------
  buf
    ..writeln()
    ..writeln('  ${model.name} copyWith({');
  for (final col in fields) {
    final base = col.type == ColumnType.foreignKey ? 'int' : _dartTypeFor(col);
    final type = base.endsWith('?') ? base : '$base?';
    final name = col.type == ColumnType.foreignKey
        ? '${_camel(col.name)}Id'
        : _camel(col.name);
    buf.writeln('    $type $name,');
  }
  buf.writeln('  }) =>');
  buf.writeln('      ${model.name}(');
  for (final col in fields) {
    final name = col.type == ColumnType.foreignKey
        ? '${_camel(col.name)}Id'
        : _camel(col.name);
    buf.writeln('        $name: $name ?? this.$name,');
  }
  buf.writeln('      );');

  // Static relations ------------------------------------------------------
  // Forward relations declared on this model (belongs-to + many-to-many).
  final relationDescriptors = <_RelationEmit>[];

  for (final col in model.foreignKeyColumns) {
    final ref = col.relationship!.references!;
    final fkColumn = '${col.name}_id';
    final relName = _camel(col.name);
    buf
      ..writeln()
      ..writeln('  static final Relation<${model.name}, $ref> $relName =')
      ..writeln('      BelongsToRelation<${model.name}, $ref>(')
      ..writeln("        parentTable: '${model.tableName}',")
      ..writeln("        childTable: '${_snake(ref)}',")
      ..writeln("        name: '$relName',")
      ..writeln("        parentForeignKey: '$fkColumn',")
      ..writeln('        childMeta: ${ref}Table.metadata,')
      ..writeln('      );');
    relationDescriptors.add(_RelationEmit(
      kind: RelationKind.belongsTo,
      childType: ref,
      relationName: relName,
    ));
  }

  for (final col in m2mFields) {
    final ref = col.relationship!.references!;
    final junction = _junction(model.name, ref);
    final relName = _camel(col.name);
    buf
      ..writeln()
      ..writeln('  static final Relation<${model.name}, $ref> $relName =')
      ..writeln('      ManyToManyRelation<${model.name}, $ref>(')
      ..writeln("        parentTable: '${model.tableName}',")
      ..writeln("        childTable: '${_snake(ref)}',")
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
      final junction = _junction(inverse.fromModel, inverse.toModel);
      buf
        ..writeln()
        ..writeln(
            '  static final Relation<${model.name}, ${inverse.fromModel}> '
            '$relName =')
        ..writeln(
            '      ManyToManyRelation<${model.name}, ${inverse.fromModel}>(')
        ..writeln("        parentTable: '${model.tableName}',")
        ..writeln("        childTable: '${_snake(inverse.fromModel)}',")
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
      final fkColumn = '${inverse.fromColumn}_id';
      buf
        ..writeln()
        ..writeln(
            '  static final Relation<${model.name}, ${inverse.fromModel}> '
            '$relName =')
        ..writeln('      HasManyRelation<${model.name}, ${inverse.fromModel}>(')
        ..writeln("        parentTable: '${model.tableName}',")
        ..writeln("        childTable: '${_snake(inverse.fromModel)}',")
        ..writeln("        name: '$relName',")
        ..writeln("        childForeignKey: '$fkColumn',")
        ..writeln('        childMeta: ${inverse.fromModel}Table.metadata,')
        ..writeln('      );');
      relationDescriptors.add(_RelationEmit(
        kind: RelationKind.hasMany,
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
        ? (col.constraints.isNull ? 'int?' : 'int')
        : _dartTypeFor(col);
    final dbColumn =
        col.type == ColumnType.foreignKey ? '${col.name}_id' : col.name;
    final fieldName = col.type == ColumnType.foreignKey
        ? '${_camel(col.name)}Id'
        : _camel(col.name);
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
      .map((c) =>
          c.type == ColumnType.foreignKey ? "'${c.name}_id'" : "'${c.name}'")
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
  // FK columns always come back as int (or null).
  if (col.type == ColumnType.foreignKey) {
    return col.constraints.isNull ? '$expr as int?' : '$expr as int';
  }

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
    default:
      final base = _baseDartType(col);
      return '$expr as $base${nullable ? '?' : ''}';
  }
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

String _encode(String fieldName, ColumnDefinition col) {
  switch (col.type) {
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

String _junction(String a, String b) {
  final pair = [_snake(a), _snake(b)]..sort();
  return pair.join('_');
}
