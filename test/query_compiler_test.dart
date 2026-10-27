/// Golden-SQL tests for the [Query] / [SqlCompiler] pipeline.
///
/// These tests pin down the exact SQL emitted for every clause shape
/// the runtime supports, so accidental regressions (re-introducing `?`
/// placeholders, double-binding parameters, mis-ordered clauses, etc.)
/// fail loudly. They run entirely in-process - no Postgres required.
library gisila.test.query_compiler_test;

import 'package:gisila_orm/gisila.dart';
import 'package:postgres/postgres.dart'
    show Result, ResultRow, ResultSchema, ResultSchemaColumn, Type;
import 'package:test/test.dart';

import 'support/test_db.dart';

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

  group('upsert and keyset (ORM-17)', () {
    test('ON CONFLICT DO NOTHING, with or without a target', () {
      expect(
          Query(users())
              .insert({'email': 'a'})
              .onConflictDoNothing()
              .compile()
              .sql,
          contains(' ON CONFLICT DO NOTHING RETURNING *'));
      expect(
          Query(users())
              .insert({'email': 'a'})
              .onConflictDoNothing(['email'])
              .compile()
              .sql,
          contains(' ON CONFLICT ("email") DO NOTHING'));
    });

    test('DO UPDATE sets every inserted column but the target by default', () {
      final c = Query(users()).insert({
        'email': 'a',
        'isActive': true,
        'age': 3
      }).onConflictDoUpdate(['email']).compile();
      expect(
          c.sql,
          endsWith(' ON CONFLICT ("email") DO UPDATE SET '
              '"is_active" = EXCLUDED."is_active", "age" = EXCLUDED."age" '
              'RETURNING *'));
    });

    test('DO UPDATE with an explicit column list', () {
      expect(
          Query(users())
              .insert({'email': 'a', 'age': 3, 'is_active': true})
              .onConflictDoUpdate(['email'], update: ['age'])
              .compile()
              .sql,
          contains('DO UPDATE SET "age" = EXCLUDED."age" RETURNING'));
    });

    test('DO UPDATE needs a target', () {
      expect(() => Query(users()).insert({'a': 1}).onConflictDoUpdate([]),
          throwsArgumentError);
    });

    test('after() seeks past the last key and orders by it', () {
      final first = Query(users()).after(id, null).limit(2).compile();
      expect(first.sql, endsWith('ORDER BY "users"."id" ASC LIMIT 2'));
      expect(first.sql, isNot(contains('WHERE')));
      final next = Query(users()).after(id, 10, descending: true).compile();
      expect(next.sql, contains('WHERE ("users"."id" < \$1)'));
      expect(next.sql, contains('ORDER BY "users"."id" DESC'));
      expect(next.params, [10]);
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

  group('without WHERE', () {
    test('UPDATE and DELETE refuse to touch every row by accident', () {
      expect(() => Query(users()).update({'email': 'x'}).compile(),
          throwsA(isA<InvalidQueryBuilderException>()));
      expect(() => Query(users()).delete().compile(),
          throwsA(isA<InvalidQueryBuilderException>()));
    });

    test('.all() opts in', () {
      expect(Query(users()).update({'email': 'x'}).all().compile().sql,
          'UPDATE "users" SET "email" = \$1 RETURNING *');
      expect(Query(users()).delete().all().compile().sql,
          'DELETE FROM "users" RETURNING *');
    });

    test('a WHERE added on the mutation builder counts', () {
      expect(Query(users()).delete().where(id.eq(1)).compile().sql,
          'DELETE FROM "users" WHERE ("users"."id" = \$1) RETURNING *');
    });
  });

  group('RawSql', () {
    test(r'renumbers $n to the statement and leaves ? alone', () {
      final c = Query(users())
          .where(id.eq(5))
          .where(RawSql<bool>(
              "data ? 'tags' AND score > \$2 AND rank < \$1", [3, 10]))
          .compile();
      expect(c.sql,
          contains("AND (data ? 'tags' AND score > \$3 AND rank < \$2))"));
      expect(c.params, [5, 3, 10]);
    });

    test('keeps an OR inside the fragment', () {
      final c = Query(users())
          .where(id.eq(5))
          .where(const RawSql<bool>('a OR b'))
          .compile();
      expect(c.sql, endsWith('WHERE (("users"."id" = \$1) AND (a OR b))'));
    });

    test('rejects placeholders that do not match the parameters', () {
      Object compile(RawSql<bool> raw) => Query(users()).where(raw).compile();
      expect(() => compile(const RawSql<bool>('a = \$1')), throwsArgumentError);
      expect(() => compile(const RawSql<bool>('a = \$2', [1])),
          throwsArgumentError);
      expect(() => compile(const RawSql<bool>('a = \$1', [1, 2])),
          throwsArgumentError);
      expect(
          () => compile(const RawSql<bool>('a = ?', [1])), throwsArgumentError);
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

  group('identifier quoting', () {
    const evil = 'id" , (SELECT pw FROM admins) AS "x';

    test('safeTk escapes inner double quotes', () {
      expect('a"b'.safeTk, '"a""b"');
      expect(evil.safeTk, '"id"" , (SELECT pw FROM admins) AS ""x"');
    });

    test('safeTk stays idempotent for well-formed quoted identifiers', () {
      expect('"users"'.safeTk, '"users"');
      expect('"a""b"'.safeTk, '"a""b"');
      expect('users'.safeTk.safeTk, '"users"');
    });

    test('safeTk re-escapes text that only looks quoted', () {
      expect('"a" , (SELECT 1) , "b"'.safeTk, '"""a"" , (SELECT 1) , ""b"""');
    });

    test('select() projection cannot inject a subquery', () {
      final c = Query(users()).select([evil]).compile();
      expect(c.sql,
          'SELECT "users"."id"" , (SELECT pw FROM admins) AS ""x" FROM "users"');
    });

    test('insert/update map keys cannot inject', () {
      final ins = Query(users()).insert({'x") values (1); --': 1}).compile();
      expect(
          ins.sql, startsWith('INSERT INTO "users" ("x"") values (1); --")'));
      final upd = Query(users()).update({'a" = 1, "b': 2}).all().compile();
      expect(upd.sql, startsWith('UPDATE "users" SET "a"" = 1, ""b" = \$1'));
    });

    test('safe literal only passes through well-formed literals', () {
      expect("'ok'".safe, "'ok'");
      expect("'a' OR '1'='1'".safe, "'''a'' OR ''1''=''1'''");
    });
  });

  group('terminal operations', () {
    /// A mock that answers every statement with one `count` row of [n].
    MockDbContext counting(int n) {
      final schema = ResultSchema([
        ResultSchemaColumn(
            typeOid: 20, type: Type.bigInteger, columnName: 'count'),
      ]);
      return MockDbContext(
        onExecute: (_, __) => Result(
          rows: [
            ResultRow(values: [n], schema: schema)
          ],
          affectedRows: 1,
          schema: schema,
        ),
      );
    }

    test('count() ignores ORDER BY, LIMIT and OFFSET (ORM-07)', () async {
      final db = counting(42);
      final q = Query(users())
          .where(isActive.eq(true))
          .orderBy(createdAt, desc: true)
          .limit(10)
          .offset(20);
      expect(await q.count(db), 42);
      expect(
        db.sqls.single,
        'SELECT COUNT(*)::bigint AS "count" FROM "users" '
        'WHERE ("users"."is_active" = \$1)',
      );
      expect(db.params.single, [true]);
      // The page itself still has them.
      expect(q.compile().sql, endsWith('LIMIT 10 OFFSET 20'));
    });

    test('count() with DISTINCT or GROUP BY counts rows of a subquery',
        () async {
      final db = counting(3);
      await Query(users()).select(['age']).distinct().orderBy(age).count(db);
      await Query(users()).groupBy(age).count(db);
      expect(
        db.sqls[0],
        'SELECT COUNT(*)::bigint AS "count" FROM '
        '(SELECT DISTINCT "users"."age" FROM "users") AS "_counted"',
      );
      expect(
        db.sqls[1],
        'SELECT COUNT(*)::bigint AS "count" FROM '
        '(SELECT 1 FROM "users" GROUP BY "users"."age") AS "_counted"',
      );
    });

    test('one() and first() leave the builder unchanged (ORM-08)', () async {
      final db = MockDbContext();
      final q = Query(users()).where(isActive.eq(true));
      await q.first(db);
      await expectLater(q.one(db), throwsA(isA<QueryNoRowsException>()));
      expect(db.sqls[0], endsWith('LIMIT 1'));
      expect(db.sqls[1], endsWith('LIMIT 2'));
      expect(q.compile().sql, isNot(contains('LIMIT')));
      final paged = Query(users()).limit(50);
      await paged.first(db);
      expect(paged.compile().sql, endsWith('LIMIT 50'));
    });

    test('eq(null) / neq(null) compile to IS [NOT] NULL (ORM-09)', () {
      const deletedAt =
          ColumnRef<DateTime?>(table: 'users', column: 'deleted_at');
      final isNull = Query(users()).where(deletedAt.eq(null)).compile();
      expect(isNull.sql, endsWith('WHERE ("users"."deleted_at" IS NULL)'));
      expect(isNull.params, isEmpty);
      final notNull = Query(users()).where(deletedAt.neq(null)).compile();
      expect(notNull.sql, endsWith('WHERE ("users"."deleted_at" IS NOT NULL)'));
      final value =
          Query(users()).where(deletedAt.eq(DateTime.utc(2026))).compile();
      expect(value.sql, endsWith('WHERE ("users"."deleted_at" = \$1)'));
    });
  });
}
