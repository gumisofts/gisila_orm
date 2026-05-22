/// Integration tests for [Database.transaction]. Skipped when no
/// docker-compose Postgres is reachable on `localhost:5454`.
library gisila.test.transaction_test;

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late bool hasDb;

  setUpAll(() async {
    hasDb = await isTestDbAvailable();
  });

  test('transaction body sees a TxDbContext, not a raw session', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    final result = await withTestDb<bool>((db, _) async {
      return await db.transaction<bool>((tx) async {
        expect(tx, isA<TxDbContext>());
        await tx.execute('CREATE TABLE t1 (id BIGSERIAL PRIMARY KEY)');
        return true;
      });
    });
    expect(result, isTrue);
  });

  test('throwing inside transaction rolls back all writes', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    final outcome = await withTestDb<int>((db, _) async {
      await db.execute(
        'CREATE TABLE t (id BIGSERIAL PRIMARY KEY, n INTEGER NOT NULL)',
      );
      try {
        await db.transaction((tx) async {
          await tx.execute(
            'INSERT INTO t (n) VALUES (\$1)',
            parameters: [1],
          );
          throw StateError('boom');
        });
      } catch (_) {/* expected */}
      final res = await db.execute('SELECT COUNT(*)::int AS c FROM t');
      return (res.first.toColumnMap()['c'] as int);
    });
    expect(outcome, 0, reason: 'rolled-back insert should not be visible');
  });

  test('committed inserts persist outside the transaction', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    final outcome = await withTestDb<int>((db, _) async {
      await db.execute(
        'CREATE TABLE t (id BIGSERIAL PRIMARY KEY, n INTEGER NOT NULL)',
      );
      await db.transaction((tx) async {
        await tx.execute(
          'INSERT INTO t (n) VALUES (\$1), (\$2)',
          parameters: [1, 2],
        );
      });
      final res = await db.execute('SELECT COUNT(*)::int AS c FROM t');
      return (res.first.toColumnMap()['c'] as int);
    });
    expect(outcome, 2);
  });
}
