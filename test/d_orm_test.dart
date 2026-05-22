/// End-to-end smoke test for the public surface re-exported from
/// `package:gisila_orm/gisila.dart`. Uses [MockDbContext] so it never
/// touches a real Postgres - this is the canary test that fails the
/// fastest if any part of the runtime API breaks at the import level.
library gisila.test.d_orm_test;

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  test('public API exports the canonical Query<T> + Expr surface', () {
    // Just typing these forces the analyzer to confirm every name is
    // exported. If a future refactor accidentally drops one of these
    // re-exports the test file stops compiling.
    const meta = TableMeta<Map<String, dynamic>>(
      tableName: 'users',
      columnNames: ['id'],
      fromRow: _identity,
    );
    const idCol = ColumnRef<int>(table: 'users', column: 'id');
    final expr = idCol.eq(1);
    expect(expr, isA<Expr<bool>>());
    expect(SqlCompiler().compile(expr), '("users"."id" = \$1)');
    expect(Query(meta), isA<Query<Map<String, dynamic>>>());
  });

  test('Query<T> + MockDbContext round-trips a simple SELECT', () async {
    const meta = TableMeta<Map<String, dynamic>>(
      tableName: 'users',
      columnNames: ['id', 'email'],
      fromRow: _identity,
    );
    final mock = MockDbContext();
    await Query(meta)
        .where(const ColumnRef<String>(table: 'users', column: 'email')
            .eq('a@b.com'))
        .all(mock);
    expect(mock.callCount, 1);
    expect(mock.sqls.single, contains('FROM "users"'));
    expect(mock.params.single, ['a@b.com']);
  });
}

Map<String, dynamic> _identity(Map<String, dynamic> row) => row;
