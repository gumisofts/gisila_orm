/// Typed relation references used by `Query<T>.preload(...)`.
///
/// Codegen emits a `static const Relation<Parent, Child>` for each
/// schema-declared relationship (e.g. `User.posts`). At call sites the
/// user composes them as plain values:
///
/// ```dart
/// Query<User>().preload([
///   User.posts,
///   User.posts.then(Post.comments),
/// ]).all(db);
/// ```
///
/// Each [Relation] carries the [TableMeta] of its child, which makes
/// the relation tree self-describing - the [Preloader] can resolve and
/// hydrate the entire chain without consulting a global registry.
library gisila.query.relation;

import 'package:gisila_orm/query/table_meta.dart';

/// Cardinality and direction of a relation.
enum RelationKind { hasMany, hasOne, belongsTo, manyToMany }

/// Metadata for a single relationship from [Parent] to [Child].
abstract class Relation<Parent, Child> {
  const Relation();

  /// Parent table name.
  String get parentTable;

  /// Child table name.
  String get childTable;

  /// Logical name on the parent (e.g. `posts`).
  String get name;

  /// Cardinality.
  RelationKind get kind;

  /// Child-side metadata so the preloader can hydrate `Child` rows
  /// without a global registry lookup.
  TableMeta<Child> get childMeta;

  /// Nested preload chain for `Parent.posts.then(Post.comments)`.
  List<Relation<dynamic, dynamic>> get nested;

  /// Build a new relation that preloads [next] after this one resolves.
  /// Used to express deep eager loads.
  Relation<Parent, Child> then(Relation<Child, dynamic> next);

  /// Convert a heterogeneous [items] list into the strongly-typed
  /// `List<Child>` that user-facing accessors expect.
  ///
  /// This relies on Dart's reified generics: even though the
  /// preloader holds the relation as `Relation<dynamic, dynamic>`,
  /// the [Child] type parameter is preserved at runtime and the
  /// `.cast<Child>()` here correctly produces e.g. `List<Post>`.
  List<Child> typedListOf(Iterable<Object?> items) =>
      items.cast<Child>().toList(growable: false);

  /// Convert a single hydrated value into the typed `Child?` slot
  /// used by HasOne / BelongsTo accessors.
  Child? typedSingleOf(Object? value) => value as Child?;
}

/// A one-to-many relation: `parent.id = child.<fk>`.
class HasManyRelation<Parent, Child> extends Relation<Parent, Child> {
  @override
  final String parentTable;
  @override
  final String childTable;
  @override
  final String name;

  /// Foreign key column on the child that points back to the parent.
  final String childForeignKey;

  /// Primary key column on the parent (defaults to `id`).
  final String parentPrimaryKey;

  @override
  final TableMeta<Child> childMeta;

  @override
  final List<Relation<dynamic, dynamic>> nested;

  const HasManyRelation({
    required this.parentTable,
    required this.childTable,
    required this.name,
    required this.childForeignKey,
    required this.childMeta,
    this.parentPrimaryKey = 'id',
    this.nested = const [],
  });

  @override
  RelationKind get kind => RelationKind.hasMany;

  @override
  Relation<Parent, Child> then(Relation<Child, dynamic> next) =>
      HasManyRelation(
        parentTable: parentTable,
        childTable: childTable,
        name: name,
        childForeignKey: childForeignKey,
        childMeta: childMeta,
        parentPrimaryKey: parentPrimaryKey,
        nested: [...nested, next],
      );
}

/// A one-to-one inverse relation: `parent.id = child.<fk>` with
/// uniqueness on the child fk.
class HasOneRelation<Parent, Child> extends Relation<Parent, Child> {
  @override
  final String parentTable;
  @override
  final String childTable;
  @override
  final String name;

  final String childForeignKey;
  final String parentPrimaryKey;

  @override
  final TableMeta<Child> childMeta;

  @override
  final List<Relation<dynamic, dynamic>> nested;

  const HasOneRelation({
    required this.parentTable,
    required this.childTable,
    required this.name,
    required this.childForeignKey,
    required this.childMeta,
    this.parentPrimaryKey = 'id',
    this.nested = const [],
  });

  @override
  RelationKind get kind => RelationKind.hasOne;

  @override
  Relation<Parent, Child> then(Relation<Child, dynamic> next) => HasOneRelation(
        parentTable: parentTable,
        childTable: childTable,
        name: name,
        childForeignKey: childForeignKey,
        childMeta: childMeta,
        parentPrimaryKey: parentPrimaryKey,
        nested: [...nested, next],
      );
}

/// A many-to-one (owning) side: `parent.<fk> = child.id`.
class BelongsToRelation<Parent, Child> extends Relation<Parent, Child> {
  @override
  final String parentTable;
  @override
  final String childTable;
  @override
  final String name;

  /// Foreign key column on the parent.
  final String parentForeignKey;

  /// Primary key column on the child (defaults to `id`).
  final String childPrimaryKey;

  @override
  final TableMeta<Child> childMeta;

  @override
  final List<Relation<dynamic, dynamic>> nested;

  const BelongsToRelation({
    required this.parentTable,
    required this.childTable,
    required this.name,
    required this.parentForeignKey,
    required this.childMeta,
    this.childPrimaryKey = 'id',
    this.nested = const [],
  });

  @override
  RelationKind get kind => RelationKind.belongsTo;

  @override
  Relation<Parent, Child> then(Relation<Child, dynamic> next) =>
      BelongsToRelation(
        parentTable: parentTable,
        childTable: childTable,
        name: name,
        parentForeignKey: parentForeignKey,
        childMeta: childMeta,
        childPrimaryKey: childPrimaryKey,
        nested: [...nested, next],
      );
}

/// A many-to-many relation through an explicit junction table.
class ManyToManyRelation<Parent, Child> extends Relation<Parent, Child> {
  @override
  final String parentTable;
  @override
  final String childTable;
  @override
  final String name;

  /// Junction table that joins `parent` and `child`.
  final String junctionTable;

  /// Junction column referencing the parent primary key.
  final String junctionParentKey;

  /// Junction column referencing the child primary key.
  final String junctionChildKey;

  /// Primary keys on each side (default `id`).
  final String parentPrimaryKey;
  final String childPrimaryKey;

  @override
  final TableMeta<Child> childMeta;

  @override
  final List<Relation<dynamic, dynamic>> nested;

  const ManyToManyRelation({
    required this.parentTable,
    required this.childTable,
    required this.name,
    required this.junctionTable,
    required this.junctionParentKey,
    required this.junctionChildKey,
    required this.childMeta,
    this.parentPrimaryKey = 'id',
    this.childPrimaryKey = 'id',
    this.nested = const [],
  });

  @override
  RelationKind get kind => RelationKind.manyToMany;

  @override
  Relation<Parent, Child> then(Relation<Child, dynamic> next) =>
      ManyToManyRelation(
        parentTable: parentTable,
        childTable: childTable,
        name: name,
        junctionTable: junctionTable,
        junctionParentKey: junctionParentKey,
        junctionChildKey: junctionChildKey,
        childMeta: childMeta,
        parentPrimaryKey: parentPrimaryKey,
        childPrimaryKey: childPrimaryKey,
        nested: [...nested, next],
      );
}
