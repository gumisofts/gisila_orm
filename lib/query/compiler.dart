/// Compile a typed [Expr] AST or a [Query] into PostgreSQL-flavoured
/// SQL with `$1, $2, ...` parameter placeholders.
///
/// `SqlCompiler` is the **only** place in the codebase that builds SQL
/// strings; every fluent operation eventually goes through here.
library gisila.query.compiler;

import 'package:gisila_orm/database/extensions.dart';
import 'package:gisila_orm/database/postgres/types/vector.dart';
import 'package:gisila_orm/query/expression.dart';

/// A finished SQL statement ready to send to a [DbContext].
class CompiledSql {
  final String sql;
  final List<Object?> params;

  const CompiledSql(this.sql, this.params);

  @override
  String toString() => 'CompiledSql(sql: $sql, params: $params)';
}

/// Walks an [Expr] tree to produce a SQL fragment and a flat parameter
/// list. Held by larger statement compilers ([selectSql], [insertSql],
/// etc.) which thread a single instance through to keep `$n` indices
/// monotonically increasing across SET lists, WHERE clauses, RETURNING
/// clauses, and so on.
class SqlCompiler implements ExprVisitor<String> {
  final List<Object?> _params = [];

  /// The bound parameters emitted so far, in `$1..$n` order.
  List<Object?> get params => List.unmodifiable(_params);

  /// Append a single parameter and return its placeholder (e.g. `$3`).
  ///
  /// [Vector] values are transparently converted to their pgvector text
  /// form and cast with `::vector`, so `InsertQuery` / `UpdateQuery`
  /// can bind a [Vector] field directly without the caller having to
  /// know the wire format.
  String bind(Object? value) {
    if (value is Vector) {
      _params.add(value.toSqlLiteral());
      return '\$${_params.length}::vector';
    }
    _params.add(value);
    return '\$${_params.length}';
  }

  /// Compile an expression into a SQL fragment.
  String compile(Expr<dynamic> expr) => expr.accept(this);

  @override
  String visitColumnRef(ColumnRef expr) =>
      '${expr.table.safeTk}.${expr.column.safeTk}';

  @override
  String visitLiteral(Literal expr) => bind(expr.value);

  @override
  String visitBinOp(BinOp expr) {
    final l = compile(expr.left);
    final r = compile(expr.right);
    return '($l ${expr.op} $r)';
  }

  @override
  String visitUnaryOp(UnaryOp expr) => '(${expr.op} ${compile(expr.operand)})';

  @override
  String visitFuncCall(FuncCall expr) {
    if (expr.infix && expr.args.length == 2) {
      final l = compile(expr.args[0]);
      final r = compile(expr.args[1]);
      return '($l ${expr.name} $r)';
    }
    final args = expr.args.map(compile).join(', ');
    return '${expr.name}($args)';
  }

  @override
  String visitInList(InList expr) {
    if (expr.values.isEmpty) {
      // `x IN ()` is a syntax error in Postgres; canonical no-match.
      return '(FALSE)';
    }
    final col = visitColumnRef(expr.column);
    final placeholders = expr.values.map(bind).join(', ');
    return '($col IN ($placeholders))';
  }

  @override
  String visitBetween(Between expr) {
    final col = visitColumnRef(expr.column);
    final lo = compile(expr.lower);
    final hi = compile(expr.upper);
    return '($col BETWEEN $lo AND $hi)';
  }

  @override
  String visitNullCheck(NullCheck expr) {
    final operand = compile(expr.operand);
    return expr.isNull ? '($operand IS NULL)' : '($operand IS NOT NULL)';
  }

  @override
  String visitVectorLiteral(VectorLiteral expr) {
    _params.add(expr.value.toSqlLiteral());
    return '\$${_params.length}::vector';
  }

  @override
  String visitRawSql(RawSql expr) {
    // Bind parameters via this compiler so $n indices stay correct, then
    // splice them back into the raw SQL string.
    if (expr.params.isEmpty) return expr.sql;
    final placeholders = expr.params.map(bind).toList();
    var i = 0;
    return expr.sql.replaceAllMapped(
      RegExp(r'\?'),
      (_) => placeholders[i++],
    );
  }
}
