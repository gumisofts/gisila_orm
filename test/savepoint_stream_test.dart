/// Savepoints, nested transactions (ORM-12) and cursor-backed streams
/// (ORM-13) against a real Postgres on `localhost:5454`.
library gisila.test.savepoint_stream_test;

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

Future<List<int>> _ns(DbContext db) async => [
      for (final r in await db.execute('SELECT n FROM t ORDER BY n'))
        r[0] as int,
    ];

void main() {
  late bool hasDb;
  setUpAll(() async => hasDb = await isTestDbAvailable());

  Future<void> withTable(Future<void> Function(Database db) body) async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    await withTestDb((db, _) async {
      await db.execute('CREATE TABLE t (n INTEGER PRIMARY KEY)');
      await body(db);
    });
  }

  group('savepoints', () {
    test('a failed savepoint rolls back only its own work', () async {
      await withTable((db) async {
        await db.transaction((tx) async {
          await tx.execute('INSERT INTO t VALUES (1)');
          await expectLater(
            tx.savepoint((sp) async {
              await sp.execute('INSERT INTO t VALUES (2)');
              await sp.execute('INSERT INTO t VALUES (1)'); // duplicate
            }),
            throwsA(isA<PostgresUniqueViolationException>()),
          );
          await tx.execute('INSERT INTO t VALUES (3)');
        });
        expect(await _ns(db.context()), [1, 3]);
      });
    });

    test('a Dart error in a savepoint undoes its writes too', () async {
      await withTable((db) async {
        await db.transaction((tx) async {
          await expectLater(
            tx.savepoint((sp) async {
              await sp.execute('INSERT INTO t VALUES (2)');
              throw StateError('no');
            }),
            throwsStateError,
          );
          expect(await tx.savepoint((sp) async => 'ok'), 'ok');
        });
        expect(await _ns(db.context()), isEmpty);
      });
    });

    test('nested db.transaction is a savepoint of the outer one', () async {
      // withTestDb pins the pool to one connection: a nested transaction
      // that took a second connection would hang here.
      await withTable((db) async {
        await db.transaction((tx) async {
          await tx.execute('INSERT INTO t VALUES (1)');
          await db.transaction((inner) async {
            await inner.execute('INSERT INTO t VALUES (2)');
          });
          try {
            await db.transaction((inner) async {
              await inner.execute('INSERT INTO t VALUES (3)');
              throw StateError('inner fails');
            });
          } on StateError {/* expected */}
        });
        expect(await _ns(db.context()), [1, 2]);

        // And the outer failing undoes the nested work.
        try {
          await db.transaction((tx) async {
            await db.transaction(
                (inner) => inner.execute('INSERT INTO t VALUES (10)'));
            throw StateError('outer fails');
          });
        } on StateError {/* expected */}
        expect(await _ns(db.context()), [1, 2]);
      });
    });

    test('a transaction started after the outer one ended is its own',
        () async {
      await withTable((db) async {
        late Future<void> Function() later;
        await db.transaction((tx) async {
          later = () =>
              db.transaction((t2) => t2.execute('INSERT INTO t VALUES (5)'));
        });
        await later();
        expect(await _ns(db.context()), [5]);
      });
    });
  });

  group('stream', () {
    Future<void> fill(Database db, int n) =>
        db.execute('INSERT INTO t SELECT g FROM generate_series(1, \$1::int) g',
            parameters: [n]);

    test('reads every row across several cursor batches, in order', () async {
      await withTable((db) async {
        await fill(db, cursorBatchSize * 2 + 7);
        final got = await db
            .context()
            .stream('SELECT n FROM t WHERE n > \$1 ORDER BY n', parameters: [0])
            .map((r) => r[0] as int)
            .toList();
        expect(got, [for (var i = 1; i <= cursorBatchSize * 2 + 7; i++) i]);
      });
    });

    test('reads through a cursor, closed when the stream is done', () async {
      await withTable((db) async {
        await fill(db, 3);
        await db.transaction((tx) async {
          Future<int> cursors() async =>
              (await tx.execute("SELECT count(*)::int FROM pg_cursors "
                      "WHERE name LIKE 'gisila_cursor_%'"))
                  .first[0] as int;
          await for (final _ in tx.stream('SELECT n FROM t')) {
            expect(await cursors(), 1);
          }
          expect(await cursors(), 0);

          // Cancelling early closes it as well.
          await tx.stream('SELECT n FROM t').first;
          expect(await cursors(), 0);
        });
      });
    });

    test('cancelling early frees the connection', () async {
      await withTable((db) async {
        await fill(db, cursorBatchSize * 3);
        final first = db.context().stream('SELECT n FROM t').take(3);
        expect(await first.length, 3);
        // One pooled connection: this would hang if the stream held it.
        expect(await _ns(db.context()), hasLength(cursorBatchSize * 3));
      });
    });

    test('an error mid-stream reaches the listener once', () async {
      await withTable((db) async {
        await fill(db, cursorBatchSize + 10);
        final errors = <Object>[];
        final rows = <Object?>[];
        await db
            .context()
            .stream('SELECT 1 / (n - \$1) FROM t ORDER BY n',
                parameters: [cursorBatchSize + 5])
            .handleError(errors.add)
            .forEach(rows.add);
        expect(errors, hasLength(1));
        expect(errors.single, isA<PostgresException>());
        expect(rows, hasLength(cursorBatchSize));
        expect(await _ns(db.context()), hasLength(cursorBatchSize + 10));
      });
    });

    test('statements a cursor cannot run are still streamed', () async {
      await withTable((db) async {
        final got = await db
            .context()
            .stream('INSERT INTO t VALUES (1), (2) RETURNING n')
            .map((r) => r[0])
            .toList();
        expect(got, [1, 2]);
      });
    });
  });
}
