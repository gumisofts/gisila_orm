/// Golden-SQL tests for the [Query] / [SqlCompiler] pipeline.
///
/// These tests pin down the exact SQL emitted for every clause shape
/// the runtime supports, so accidental regressions (re-introducing `?`
/// placeholders, double-binding parameters, mis-ordered clauses, etc.)
/// fail loudly. They run entirely in-process - no Postgres required.
library gisila.test.query_compiler_test;

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

void main() {
  // Lightweight TableMeta. We don't hydrate rows in this test, so
  // `fromRow` is a no-op stub.
  TableMeta<Map<String, dynamic>> users() => TableMeta<Map<String, dynamic>>(
        tableName: 'users',
        primaryKey: 'id',
        columnNames: const ['id', 'email', 'is_active', 'age', 'created_at'],
        fromRow: (r) => r,
      );

  const id = ColumnRef<int>(table: 'users', column: 'id');
  const email = ColumnRef<String>(table: 'users', column: 'email');
  const isActive = ColumnRef<bool>(table: 'users', column: 'is_active');
  const age = ColumnRef<int>(table: 'users', column: 'age');
  const createdAt = ColumnRef<DateTime>(table: 'users', column: 'created_at');

  group('SELECT', () {
    test('default projection lists every column, fully qualified', () {
      final c = Query(users()).compile();
      expect(
        c.sql,
        'SELECT "users"."id", "users"."email", "users"."is_active", '
        '"users"."age", "users"."created_at" FROM "users"',
      );
      expect(c.params, isEmpty);
    });

    test('WHERE binds parameters in order with \$n placeholders', () {
      final c = Query(users())
          .where(email.like('%@gumi.com').and(isActive.eq(true)))
          .compile();
      expect(
        c.sql,
        endsWith(
          'WHERE (("users"."email" LIKE \$1) AND ("users"."is_active" = \$2))',
        ),
      );
      expect(c.params, ['%@gumi.com', true]);
    });

    test('ORDER BY honors direction and NULLS FIRST', () {
      final c = Query(users())
          .orderBy(createdAt, desc: true, nullsFirst: true)
          .orderBy(id)
          .compile();
      expect(
        c.sql,
        endsWith(
            'ORDER BY "users"."created_at" DESC NULLS FIRST, "users"."id" ASC'),
      );
    });

    test('LIMIT / OFFSET are appended as raw integers (no binding)', () {
      final c = Query(users()).limit(10).offset(20).compile();
      expect(c.sql, endsWith('LIMIT 10 OFFSET 20'));
      expect(c.params, isEmpty);
    });

    test('multiple where calls AND together', () {
      final c =
          Query(users()).where(isActive.eq(true)).where(age.gt(18)).compile();
      expect(c.sql, contains('WHERE'));
      expect(c.sql, contains('"users"."is_active" = \$1'));
      expect(c.sql, contains('"users"."age" > \$2'));
      expect(c.params, [true, 18]);
    });

    test('IN list binds every value', () {
      final c = Query(users()).where(id.inList(const [1, 2, 3])).compile();
      expect(c.sql, contains('"users"."id" IN (\$1, \$2, \$3)'));
      expect(c.params, [1, 2, 3]);
    });

    test('IN [] short-circuits to FALSE without binding', () {
      final c = Query(users()).where(id.inList(const <int>[])).compile();
      expect(c.sql, contains('(FALSE)'));
      expect(c.params, isEmpty);
    });

    test('BETWEEN binds two parameters', () {
      final c = Query(users()).where(age.between(18, 65)).compile();
      expect(c.sql, contains('"users"."age" BETWEEN \$1 AND \$2'));
      expect(c.params, [18, 65]);
    });

    test('isNull / isNotNull do not bind parameters', () {
      final c = Query(users()).where(email.isNull).compile();
      expect(c.sql, contains('"users"."email" IS NULL'));
      expect(c.params, isEmpty);
    });

    test('GROUP BY + HAVING share the parameter index space', () {
      final c = Query(users()).groupBy(isActive).having(age.gt(30)).compile();
      expect(c.sql, contains('GROUP BY "users"."is_active"'));
      expect(c.sql, contains('HAVING ("users"."age" > \$1)'));
      expect(c.params, [30]);
    });

    test('JOIN clause emits the alias and ON predicate', () {
      const orderUserId = ColumnRef<int>(table: 'orders', column: 'user_id');
      final c = Query(users())
          .join('orders', orderUserId.eqExpr(id))
          .where(isActive.eq(true))
          .compile();
      expect(
        c.sql,
        contains('INNER JOIN "orders" ON ("orders"."user_id" = "users"."id")'),
      );
      expect(c.sql, contains('WHERE ("users"."is_active" = \$1)'));
      expect(c.params, [true]);
    });

    test('count() overrides the projection but reuses WHERE bindings', () {
      final compiled = Query(users())
          .where(isActive.eq(true))
          .compile(overrideSelect: 'COUNT(*)');
      expect(compiled.sql, startsWith('SELECT COUNT(*) FROM'));
      expect(compiled.params, [true]);
    });
  });

  group('INSERT', () {
    test('emits column list, values, and RETURNING * by default', () {
      final c = Query(users()).insert({
        'email': 'a@b.com',
        'is_active': true,
      }).compile();
      expect(
        c.sql,
        'INSERT INTO "users" ("email", "is_active") '
        'VALUES (\$1, \$2) RETURNING *',
      );
      expect(c.params, ['a@b.com', true]);
    });

    test('multi-row insert reuses one parameter sequence', () {
      final c = Query(users())
          .insert({'email': 'a@b.com', 'is_active': true}).values(
              {'email': 'c@d.com', 'is_active': false}).compile();
      expect(c.sql, contains('VALUES (\$1, \$2), (\$3, \$4)'));
      expect(c.params, ['a@b.com', true, 'c@d.com', false]);
    });

    test('returning(false) drops the RETURNING clause', () {
      final c = Query(users())
          .insert({'email': 'a@b.com'})
          .returning(false)
          .compile();
      expect(c.sql, isNot(contains('RETURNING')));
    });
  });

  group('UPDATE', () {
    test('SET and WHERE share a single parameter index sequence', () {
      // Regression: the old code ran SET bindings on one counter and
      // WHERE bindings on another, producing duplicate `$1` slots.
      final c = Query(users())
          .where(id.eq(99))
          .update({'email': 'new@x.com', 'is_active': false}).compile();
      expect(
        c.sql,
        'UPDATE "users" SET "email" = \$1, "is_active" = \$2 '
        'WHERE ("users"."id" = \$3) RETURNING *',
      );
      expect(c.params, ['new@x.com', false, 99]);
    });
  });

  group('DELETE', () {
    test('emits WHERE and RETURNING by default', () {
      final c = Query(users()).where(id.eq(1)).delete().compile();
      expect(
        c.sql,
        'DELETE FROM "users" WHERE ("users"."id" = \$1) RETURNING *',
      );
      expect(c.params, [1]);
    });
  });
}
