/// Typed AST for SQL expressions.
///
/// Every expression is an `Expr<T>` whose static type matches the SQL
/// type the expression produces. The [SqlCompiler] in `compiler.dart`
/// walks this AST to emit parametrised SQL using `$1, $2, ...`.
///
/// User code never builds these nodes directly. Instead it composes
/// them through the helpers on [ColumnRef] (`eq`, `gt`, `like`, ...)
/// and on [Expr] itself (`and`, `or`, `not`).
library gisila.query.expression;

import 'package:gisila_orm/database/postgres/types/vector.dart';

/// Base class for every SQL expression that yields a value of type [T].
abstract class Expr<T> {
  const Expr();

  /// Visitor entry point used by the SQL compiler.
  R accept<R>(ExprVisitor<R> visitor);

  /// Logical AND with another boolean expression.
  Expr<bool> and(Expr<bool> other) =>
      BinOp<bool>(this as Expr<bool>, 'AND', other);

  /// Logical OR with another boolean expression.
  Expr<bool> or(Expr<bool> other) =>
      BinOp<bool>(this as Expr<bool>, 'OR', other);

  /// Logical NOT.
  Expr<bool> get not => UnaryOp<bool>('NOT', this as Expr<bool>);
}

/// Visitor protocol for emitting SQL from an expression tree.
abstract class ExprVisitor<R> {
  R visitColumnRef(ColumnRef expr);
  R visitLiteral(Literal expr);
  R visitBinOp(BinOp expr);
  R visitUnaryOp(UnaryOp expr);
  R visitFuncCall(FuncCall expr);
  R visitInList(InList expr);
  R visitBetween(Between expr);
  R visitNullCheck(NullCheck expr);
  R visitRawSql(RawSql expr);
  R visitVectorLiteral(VectorLiteral expr);
}

/// A typed reference to a table column. Codegen emits one of these
/// for every column in `User`, `Post`, etc.
class ColumnRef<T> extends Expr<T> {
  /// The unquoted column name (e.g. `email`).
  final String column;

  /// The unquoted table or alias name the column belongs to.
  final String table;

  const ColumnRef({required this.column, required this.table});

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitColumnRef(this);

  // Comparison operators -------------------------------------------------

  Expr<bool> eq(T value) => BinOp<bool>(this, '=', Literal<T>(value));
  Expr<bool> neq(T value) => BinOp<bool>(this, '<>', Literal<T>(value));
  Expr<bool> gt(T value) => BinOp<bool>(this, '>', Literal<T>(value));
  Expr<bool> gte(T value) => BinOp<bool>(this, '>=', Literal<T>(value));
  Expr<bool> lt(T value) => BinOp<bool>(this, '<', Literal<T>(value));
  Expr<bool> lte(T value) => BinOp<bool>(this, '<=', Literal<T>(value));

  Expr<bool> eqExpr(Expr<T> other) => BinOp<bool>(this, '=', other);
  Expr<bool> neqExpr(Expr<T> other) => BinOp<bool>(this, '<>', other);

  // Set membership -------------------------------------------------------

  Expr<bool> inList(Iterable<T> values) =>
      InList<T>(this, values.toList(growable: false));

  Expr<bool> between(T lower, T upper) =>
      Between<T>(this, Literal<T>(lower), Literal<T>(upper));

  // Null tests -----------------------------------------------------------

  Expr<bool> get isNull => NullCheck(this, true);
  Expr<bool> get isNotNull => NullCheck(this, false);
}

/// String-specific helpers.
extension StringColumnRefOps on ColumnRef<String> {
  Expr<bool> like(String pattern) =>
      BinOp<bool>(this, 'LIKE', Literal<String>(pattern));
  Expr<bool> ilike(String pattern) =>
      BinOp<bool>(this, 'ILIKE', Literal<String>(pattern));
}

/// String-specific helpers for nullable text columns.
///
/// Generated table columns are `ColumnRef<String?>` when `is_null: true`,
/// so define the same lookup surface there as well.
extension NullableStringColumnRefOps on ColumnRef<String?> {
  Expr<bool> like(String pattern) =>
      BinOp<bool>(this, 'LIKE', Literal<String>(pattern));
  Expr<bool> ilike(String pattern) =>
      BinOp<bool>(this, 'ILIKE', Literal<String>(pattern));
}

/// JSON/JSONB navigation helpers.
extension JsonColumnRefOps on ColumnRef<Map<String, dynamic>> {
  /// `column -> 'key'` returns a JSON value.
  Expr<Map<String, dynamic>?> field(String key) =>
      FuncCall<Map<String, dynamic>?>(
        '->',
        [this, Literal<String>(key)],
        infix: true,
      );

  /// `column ->> 'key'` returns a TEXT.
  Expr<String?> text(String key) =>
      FuncCall<String?>('->>', [this, Literal<String>(key)], infix: true);
}

/// pgvector helpers. Exposes the three distance operators that ship
/// with the `vector` extension and a `nearest` shortcut that produces
/// an `ORDER BY <distance> ASC` term ready to feed into [Query.orderBy].
///
/// ```dart
/// Query<Document>(DocumentTable.metadata)
///   .orderBy(
///     DocumentTable.embedding.cosineDistance(query),
///     // sort ascending: nearest first
///   )
///   .limit(10)
///   .all(db);
/// ```
extension VectorColumnRefOps on ColumnRef<Vector> {
  /// Euclidean (L2) distance `column <-> $1::vector`.
  Expr<double> l2Distance(Vector value) =>
      FuncCall<double>('<->', [this, VectorLiteral(value)], infix: true);

  /// Cosine distance `column <=> $1::vector`.
  Expr<double> cosineDistance(Vector value) =>
      FuncCall<double>('<=>', [this, VectorLiteral(value)], infix: true);

  /// Negative inner product `column <#> $1::vector`. (pgvector returns
  /// the negative dot product so that `ORDER BY ... ASC` still gives
  /// the most-similar items first.)
  Expr<double> innerProduct(Vector value) =>
      FuncCall<double>('<#>', [this, VectorLiteral(value)], infix: true);

  /// Generic dispatcher that picks the operator from a [VectorDistance].
  Expr<double> distance(Vector value,
      {VectorDistance metric = VectorDistance.l2}) {
    switch (metric) {
      case VectorDistance.l2:
        return l2Distance(value);
      case VectorDistance.cosine:
        return cosineDistance(value);
      case VectorDistance.innerProduct:
        return innerProduct(value);
    }
  }
}

/// Same as [VectorColumnRefOps] for nullable vector columns.
extension NullableVectorColumnRefOps on ColumnRef<Vector?> {
  Expr<double> l2Distance(Vector value) =>
      FuncCall<double>('<->', [this, VectorLiteral(value)], infix: true);
  Expr<double> cosineDistance(Vector value) =>
      FuncCall<double>('<=>', [this, VectorLiteral(value)], infix: true);
  Expr<double> innerProduct(Vector value) =>
      FuncCall<double>('<#>', [this, VectorLiteral(value)], infix: true);
  Expr<double> distance(Vector value,
      {VectorDistance metric = VectorDistance.l2}) {
    switch (metric) {
      case VectorDistance.l2:
        return l2Distance(value);
      case VectorDistance.cosine:
        return cosineDistance(value);
      case VectorDistance.innerProduct:
        return innerProduct(value);
    }
  }
}

/// Postgres array helpers.
extension ArrayColumnRefOps<T> on ColumnRef<List<T>> {
  /// `column @> ARRAY[..]` - left contains right.
  Expr<bool> contains(Iterable<T> values) =>
      BinOp<bool>(this, '@>', Literal<List<T>>(values.toList()));

  /// `column && ARRAY[..]` - arrays overlap.
  Expr<bool> overlaps(Iterable<T> values) =>
      BinOp<bool>(this, '&&', Literal<List<T>>(values.toList()));
}

/// A literal value bound as a query parameter.
class Literal<T> extends Expr<T> {
  final T? value;
  const Literal(this.value);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitLiteral(this);
}

/// `lhs <op> rhs`, e.g. `age >= 18` or `a AND b`.
class BinOp<T> extends Expr<T> {
  final Expr<dynamic> left;
  final String op;
  final Expr<dynamic> right;
  const BinOp(this.left, this.op, this.right);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitBinOp(this);
}

/// `<op> operand`, e.g. `NOT <bool>`.
class UnaryOp<T> extends Expr<T> {
  final String op;
  final Expr<dynamic> operand;
  const UnaryOp(this.op, this.operand);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitUnaryOp(this);
}

/// A SQL function or operator call. With [infix] false (the default),
/// emits `name(arg1, arg2, ...)`. With [infix] true and exactly two
/// args, emits `arg1 name arg2`.
class FuncCall<T> extends Expr<T> {
  final String name;
  final List<Expr<dynamic>> args;
  final bool infix;
  const FuncCall(this.name, this.args, {this.infix = false});

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitFuncCall(this);
}

/// `column IN ($1, $2, ...)` - efficient set membership test.
class InList<T> extends Expr<bool> {
  final ColumnRef<T> column;
  final List<T> values;
  const InList(this.column, this.values);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitInList(this);
}

/// `column BETWEEN lo AND hi`.
class Between<T> extends Expr<bool> {
  final ColumnRef<T> column;
  final Expr<T> lower;
  final Expr<T> upper;
  const Between(this.column, this.lower, this.upper);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitBetween(this);
}

/// `column IS NULL` (when [isNull] is true) or `column IS NOT NULL`.
class NullCheck extends Expr<bool> {
  final Expr<dynamic> operand;
  final bool isNull;
  const NullCheck(this.operand, this.isNull);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitNullCheck(this);
}

/// Escape hatch: a hand-written SQL fragment with optional bound
/// parameters, used for cases the AST can't model directly.
class RawSql<T> extends Expr<T> {
  final String sql;
  final List<Object?> params;
  const RawSql(this.sql, [this.params = const []]);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitRawSql(this);
}

/// A bound [Vector] literal. Compiled as `$n::vector` so pgvector's
/// distance operators work without any per-call hand-written SQL.
class VectorLiteral extends Expr<Vector> {
  final Vector value;
  const VectorLiteral(this.value);

  @override
  R accept<R>(ExprVisitor<R> visitor) => visitor.visitVectorLiteral(this);
}
