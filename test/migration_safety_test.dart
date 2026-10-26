/// Integration tests for migration locking, checksums and the
/// no-transaction directive. Skipped when no docker-compose Postgres is
/// reachable on `localhost:5454`.
library gisila.test.migration_safety_test;

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

const _widgets = Migration(
  id: '0001_widgets',
  upSql: 'CREATE TABLE widgets (id BIGSERIAL PRIMARY KEY, name TEXT);',
  downSql: 'DROP TABLE widgets;',
);

/// A second, independent pool on the same test schema, standing in for a
/// second deploy running `migrate up` at the same time.
Future<Database> _secondDb(String schema) => Database.connect(
      DatabaseConfig(connections: [
        DatabaseConnection(
          name: 'default',
          type: DatabaseType.postgresql,
          host: 'localhost',
          port: 5454,
          database: 'postgres',
          username: 'postgres',
          password: 'postgres',
          maxConnections: 1,
        ),
      ]),
      onOpen: (connection) async {
        await connection.execute('SET search_path TO "$schema", public');
      },
    );

void main() {
  late bool hasDb;

  setUpAll(() async {
    hasDb = await isTestDbAvailable();
  });

  test('concurrent up() runs apply each migration once', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    const slow = Migration(
      id: '0001_slow',
      upSql: 'SELECT pg_sleep(0.5); CREATE TABLE slow_t (id INT);',
    );
    final counts = await withTestDb<List<int>>((db, schema) async {
      final other = await _secondDb(schema);
      try {
        final results = await Future.wait([
          MigrationManager(db).up([slow]),
          MigrationManager(other).up([slow]),
        ]);
        return results.map((r) => r.applied.length).toList();
      } finally {
        await other.close();
      }
    });
    expect(counts!..sort(), [0, 1]);
  });

  group('checksums', () {
    test('up() refuses when an applied migration was edited', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      await withTestDb<void>((db, _) async {
        final manager = MigrationManager(db);
        await manager.up([_widgets]);

        const edited = Migration(
          id: '0001_widgets',
          upSql: 'CREATE TABLE widgets (id BIGSERIAL PRIMARY KEY);',
        );
        const next = Migration(
          id: '0002_gadgets',
          upSql: 'CREATE TABLE gadgets (id INT);',
        );
        expect(await manager.editedSinceApplied([edited]), ['0001_widgets']);
        await expectLater(manager.up([edited, next]),
            throwsA(isA<MigrationChecksumException>()));
        // Nothing after the check ran.
        expect(
            (await manager.listApplied()).map((a) => a.id), ['0001_widgets']);
      });
    });

    test('CRLF line endings do not count as an edit', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      await withTestDb<void>((db, _) async {
        final manager = MigrationManager(db);
        const lf = Migration(id: '0001_t', upSql: 'CREATE TABLE t (id INT);\n');
        const crlf =
            Migration(id: '0001_t', upSql: 'CREATE TABLE t (id INT);\r\n');
        await manager.up([lf]);
        expect(await manager.editedSinceApplied([crlf]), isEmpty);
      });
    });

    test('rows from before checksums are adopted, not rejected', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      await withTestDb<void>((db, _) async {
        final manager = MigrationManager(db);
        await manager.up([_widgets]);
        await db.execute('UPDATE gisila_migrations SET checksum = NULL');

        await manager.up([_widgets]);
        final applied = await manager.listApplied();
        expect(applied.single.checksum, _widgets.checksum);
      });
    });
  });

  group('no-transaction directive', () {
    const index = Migration(
      id: '0002_index',
      upSql: '-- gisila:no-transaction\n'
          'CREATE INDEX CONCURRENTLY widgets_name ON widgets (name);',
      downSql: '-- gisila:no-transaction\n'
          'DROP INDEX CONCURRENTLY widgets_name;',
    );

    test('runs statements that refuse to run in a transaction', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      await withTestDb<void>((db, _) async {
        final manager = MigrationManager(db);
        final up = await manager.up([_widgets, index]);
        expect(up.applied.map((m) => m.id), ['0001_widgets', '0002_index']);
        final idx = await db.execute(
            "SELECT 1 FROM pg_indexes WHERE indexname = 'widgets_name'");
        expect(idx, hasLength(1));

        final down =
            await manager.down(discovered: [_widgets, index], steps: 1);
        expect(down.rolledBack, hasLength(2));
      });
    });

    test('without it, the same SQL fails and is not recorded', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      const plain = Migration(
        id: '0002_index',
        upSql: 'CREATE INDEX CONCURRENTLY widgets_name ON widgets (name);',
      );
      expect(plain.upIsNonTransactional, isFalse);
      await withTestDb<void>((db, _) async {
        final manager = MigrationManager(db);
        await manager.up([_widgets]);
        await expectLater(manager.up([_widgets, plain]), throwsA(anything));
        expect(
            (await manager.listApplied()).map((a) => a.id), ['0001_widgets']);
      });
    });
  });
}
