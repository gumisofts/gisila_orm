/// Batched eager loader used by `Query<T>.preload(...)`.
///
/// For each relation in the requested tree, [Preloader] performs a
/// single `WHERE fk IN ($1, $2, ...)` query against the child table,
/// groups the result rows by their join key, and writes the typed
/// children back into each parent's [Preloadable] storage. Nested
/// relations (`User.posts.then(Post.comments)`) recurse into the
/// hydrated children in the same level-by-level fashion, so the total
/// number of SQL round-trips equals the depth of the preload tree -
/// not its breadth - eliminating the N+1 problem without resorting
/// to row-exploding outer joins.
library gisila.query.preloader;

import 'package:gisila/database/extensions.dart';
import 'package:gisila/database/postgres/exceptions/exceptions.dart';
import 'package:gisila/query/hydrator.dart';
import 'package:gisila/query/relation.dart';
import 'package:gisila/query/table_meta.dart';
import 'package:gisila/runtime/db_context.dart';
import 'package:gisila/runtime/preloadable.dart';
import 'package:postgres/postgres.dart';

class Preloader {
  const Preloader();

  /// Apply all [relations] to [parents]. Each relation runs against
  /// [db]; nested relations on each [Relation] descend into the freshly
  /// hydrated children.
  Future<void> applyTo(
    List<Object> parents,
    List<Relation<dynamic, dynamic>> relations,
    DbContext db,
  ) async {
    if (parents.isEmpty || relations.isEmpty) return;
    for (final relation in relations) {
      await _applyOne(parents, relation, db);
    }
  }

  Future<void> _applyOne(
    List<Object> parents,
    Relation<dynamic, dynamic> relation,
    DbContext db,
  ) async {
    switch (relation.kind) {
      case RelationKind.hasMany:
        await _loadHasMany(parents, relation as HasManyRelation, db);
        break;
      case RelationKind.hasOne:
        await _loadHasOne(parents, relation as HasOneRelation, db);
        break;
      case RelationKind.belongsTo:
        await _loadBelongsTo(parents, relation as BelongsToRelation, db);
        break;
      case RelationKind.manyToMany:
        await _loadManyToMany(parents, relation as ManyToManyRelation, db);
        break;
    }
  }

  // --- HasMany ----------------------------------------------------------

  Future<void> _loadHasMany(
    List<Object> parents,
    HasManyRelation relation,
    DbContext db,
  ) async {
    final keyByParent = <Object, Object?>{
      for (final p in parents) p: _readField(p, relation.parentPrimaryKey),
    };
    final keys = keyByParent.values
        .where((v) => v != null)
        .toSet()
        .toList(growable: false);
    if (keys.isEmpty) {
      _writeAllEmptyList(parents, relation.name, relation: relation);
      return;
    }

    final children = await _fetchInList(
      db: db,
      meta: relation.childMeta,
      column: relation.childForeignKey,
      keys: keys,
    );

    final groups = <Object, List<Object>>{};
    for (final child in children) {
      final fk = _readField(child, relation.childForeignKey);
      if (fk == null) continue;
      groups.putIfAbsent(fk, () => []).add(child);
    }

    for (final p in parents) {
      final pk = keyByParent[p];
      final raw =
          pk == null ? const <Object>[] : (groups[pk] ?? const <Object>[]);
      _writeRelation(p, relation.name, relation.typedListOf(raw));
    }

    if (relation.nested.isNotEmpty && children.isNotEmpty) {
      await applyTo(children, relation.nested, db);
    }
  }

  // --- HasOne -----------------------------------------------------------

  Future<void> _loadHasOne(
    List<Object> parents,
    HasOneRelation relation,
    DbContext db,
  ) async {
    final keyByParent = <Object, Object?>{
      for (final p in parents) p: _readField(p, relation.parentPrimaryKey),
    };
    final keys = keyByParent.values
        .where((v) => v != null)
        .toSet()
        .toList(growable: false);
    if (keys.isEmpty) {
      _writeAllNull(parents, relation.name);
      return;
    }

    final children = await _fetchInList(
      db: db,
      meta: relation.childMeta,
      column: relation.childForeignKey,
      keys: keys,
    );

    final byKey = <Object, Object>{};
    for (final child in children) {
      final fk = _readField(child, relation.childForeignKey);
      if (fk != null && !byKey.containsKey(fk)) {
        byKey[fk] = child;
      }
    }

    for (final p in parents) {
      final pk = keyByParent[p];
      final value = pk == null ? null : byKey[pk];
      _writeRelation(p, relation.name, relation.typedSingleOf(value));
    }

    if (relation.nested.isNotEmpty && children.isNotEmpty) {
      await applyTo(children, relation.nested, db);
    }
  }

  // --- BelongsTo --------------------------------------------------------

  Future<void> _loadBelongsTo(
    List<Object> parents,
    BelongsToRelation relation,
    DbContext db,
  ) async {
    final fkByParent = <Object, Object?>{
      for (final p in parents) p: _readField(p, relation.parentForeignKey),
    };
    final keys = fkByParent.values
        .where((v) => v != null)
        .toSet()
        .toList(growable: false);
    if (keys.isEmpty) {
      _writeAllNull(parents, relation.name);
      return;
    }

    final children = await _fetchInList(
      db: db,
      meta: relation.childMeta,
      column: relation.childPrimaryKey,
      keys: keys,
    );

    final byKey = <Object, Object>{
      for (final c in children)
        if (_readField(c, relation.childPrimaryKey) != null)
          _readField(c, relation.childPrimaryKey)!: c,
    };

    for (final p in parents) {
      final fk = fkByParent[p];
      final value = fk == null ? null : byKey[fk];
      _writeRelation(p, relation.name, relation.typedSingleOf(value));
    }

    if (relation.nested.isNotEmpty && children.isNotEmpty) {
      await applyTo(children, relation.nested, db);
    }
  }

  // --- ManyToMany -------------------------------------------------------

  Future<void> _loadManyToMany(
    List<Object> parents,
    ManyToManyRelation relation,
    DbContext db,
  ) async {
    final keyByParent = <Object, Object?>{
      for (final p in parents) p: _readField(p, relation.parentPrimaryKey),
    };
    final parentKeys = keyByParent.values
        .where((v) => v != null)
        .toSet()
        .toList(growable: false);
    if (parentKeys.isEmpty) {
      _writeAllEmptyList(parents, relation.name, relation: relation);
      return;
    }

    // 1. Junction lookup: parent_key -> [child_key, child_key, ...]
    final placeholders =
        Iterable.generate(parentKeys.length, (i) => '\$${i + 1}').join(', ');
    final junctionSql = 'SELECT '
        '${relation.junctionParentKey.safeTk}, '
        '${relation.junctionChildKey.safeTk} '
        'FROM ${relation.junctionTable.safeTk} '
        'WHERE ${relation.junctionParentKey.safeTk} IN ($placeholders)';
    final junctionRows = await db.execute(junctionSql, parameters: parentKeys);

    final pairs = <MapEntry<Object, Object>>[];
    for (final row in junctionRows) {
      final cols = row.toColumnMap();
      final p = cols[relation.junctionParentKey];
      final c = cols[relation.junctionChildKey];
      if (p == null || c == null) continue;
      pairs.add(MapEntry(p as Object, c as Object));
    }

    final childKeys = pairs.map((e) => e.value).toSet().toList(growable: false);
    if (childKeys.isEmpty) {
      _writeAllEmptyList(parents, relation.name, relation: relation);
      return;
    }

    // 2. Fetch children by primary key.
    final children = await _fetchInList(
      db: db,
      meta: relation.childMeta,
      column: relation.childPrimaryKey,
      keys: childKeys,
    );
    final childByKey = <Object, Object>{
      for (final c in children)
        if (_readField(c, relation.childPrimaryKey) != null)
          _readField(c, relation.childPrimaryKey)!: c,
    };

    // 3. Stitch.
    final groups = <Object, List<Object>>{};
    for (final pair in pairs) {
      final c = childByKey[pair.value];
      if (c == null) continue;
      groups.putIfAbsent(pair.key, () => []).add(c);
    }
    for (final p in parents) {
      final pk = keyByParent[p];
      final raw =
          pk == null ? const <Object>[] : (groups[pk] ?? const <Object>[]);
      _writeRelation(p, relation.name, relation.typedListOf(raw));
    }

    if (relation.nested.isNotEmpty && children.isNotEmpty) {
      await applyTo(children, relation.nested, db);
    }
  }

  // --- Helpers ----------------------------------------------------------

  /// Run `SELECT * FROM <meta.tableName> WHERE <column> IN ($1...$n)`
  /// and hydrate the rows into the typed model. Returned as `List<Object>`
  /// because the caller works with `Object` parents anyway.
  Future<List<Object>> _fetchInList({
    required DbContext db,
    required TableMeta meta,
    required String column,
    required List<Object?> keys,
  }) async {
    final placeholders =
        Iterable.generate(keys.length, (i) => '\$${i + 1}').join(', ');
    final cols = meta.columnNames
        .map((c) => '${meta.tableName.safeTk}.${c.safeTk}')
        .join(', ');
    final sql = 'SELECT $cols FROM ${meta.tableName.safeTk} '
        'WHERE ${column.safeTk} IN ($placeholders)';
    final result = await db.execute(sql, parameters: keys);
    final hydrator = Hydrator(meta.fromRow);
    return hydrator.hydrateAll(result).cast<Object>();
  }

  /// Write a single preloaded value onto a parent. The parent must be a
  /// [Preloadable] (which all generated models are); if not, we throw
  /// [PreloadException] so users get a clear diagnostic instead of a
  /// silent no-op.
  void _writeRelation(Object parent, String relationName, Object? value) {
    if (parent is! Preloadable) {
      throw PreloadException(
        'Cannot store preloaded "$relationName" on ${parent.runtimeType}: '
        'the model class must mix in `Preloadable`. Re-run code '
        'generation (`dart run gisila:generate`) to regenerate models.',
      );
    }
    parent.$preloaded[relationName] = value;
  }

  void _writeAllNull(List<Object> parents, String name) {
    for (final p in parents) {
      _writeRelation(p, name, null);
    }
  }

  void _writeAllEmptyList(
    List<Object> parents,
    String name, {
    Relation? relation,
  }) {
    for (final p in parents) {
      _writeRelation(
        p,
        name,
        relation == null
            ? const <Object>[]
            : relation.typedListOf(const <Object>[]),
      );
    }
  }

  /// Reflective field read via the model's `toRow()` (which all
  /// generated models provide). This avoids requiring `dart:mirrors` or
  /// per-field codegen, at the cost of an extra map allocation.
  Object? _readField(Object instance, String column) {
    final row = (instance as dynamic).toRow() as Map<String, dynamic>;
    return row[column];
  }
}

// `ResultRow` is referenced indirectly via DbContext.execute return type;
// keep the import explicit so linters don't strip it.
// ignore: unused_element
typedef _Unused = ResultRow;
