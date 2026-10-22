/// Integration tests for the [MigrationManager]. Skipped when no
/// docker-compose Postgres is reachable on `localhost:5454`.
library gisila.test.migration_test;

import 'dart:io';

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

const _upSql = '''
CREATE TABLE widgets (
  id   BIGSERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL
);
''';

const _downSql = 'DROP TABLE IF EXISTS widgets;';

Future<List<Migration>> _writeFixture(Directory tmp) async {
  final upFile = File('${tmp.path}/0001_widgets.up.sql');
  final downFile = File('${tmp.path}/0001_widgets.down.sql');
  await upFile.writeAsString(_upSql);
  await downFile.writeAsString(_downSql);
  return [
    Migration(
      id: '0001_widgets',
      upSql: _upSql,
      downSql: _downSql,
      sourcePath: upFile.path,
    ),
  ];
}

void main() {
  late bool hasDb;

  setUpAll(() async {
    hasDb = await isTestDbAvailable();
  });

  test('apply then rollback round-trips a single migration', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('gisila_mig_test_');
    try {
      final discovered = await _writeFixture(tmp);
      final outcome = await withTestDb<({int after, int rolledBack})>(
        (db, _) async {
          final manager = MigrationManager(db);

          final upRes = await manager.up(discovered);
          expect(upRes.applied.single.id, '0001_widgets');

          final widgetCountAfterUp = await db.execute(
            "SELECT COUNT(*)::int AS c FROM information_schema.tables "
            "WHERE table_name = 'widgets'",
          );
          final after = widgetCountAfterUp.first.toColumnMap()['c'] as int;

          final downRes = await manager.down(discovered: discovered, steps: 1);

          return (after: after, rolledBack: downRes.rolledBack.length);
        },
      );

      expect(outcome, isNotNull);
      expect(outcome!.after, 1, reason: 'widgets table should exist post-up');
      expect(outcome.rolledBack, 1);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('listApplied / status reflects the tracking table', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('gisila_mig_test_');
    try {
      final discovered = await _writeFixture(tmp);
      final result = await withTestDb<int>((db, _) async {
        final manager = MigrationManager(db);
        await manager.up(discovered);
        final applied = await manager.listApplied();
        return applied.length;
      });
      expect(result, 1);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('up() is idempotent: re-running applies nothing', () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    final tmp = await Directory.systemTemp.createTemp('gisila_mig_test_');
    try {
      final discovered = await _writeFixture(tmp);
      final secondCount = await withTestDb<int>((db, _) async {
        final manager = MigrationManager(db);
        await manager.up(discovered);
        final second = await manager.up(discovered);
        return second.applied.length;
      });
      expect(secondCount, 0);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  group('baseline discovery', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gisila_mig_base_');
      await File('${tmp.path}/schema.gisila.up.sql').writeAsString(_upSql);
      await File('${tmp.path}/schema.gisila.down.sql').writeAsString(_downSql);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('uses the build_runner baseline when it is the only migration',
        () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      final ids = await withTestDb<List<String>>((db, _) async {
        final manager = MigrationManager(db);
        final discovered = await manager.discoverIn(tmp.path);
        final res = await manager.up(discovered);
        return res.applied.map((m) => m.id).toList();
      });
      expect(ids, ['schema.gisila']);
    });

    test('ignores the baseline once real migrations exist', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      await Directory('${tmp.path}/migrations').create();
      await File('${tmp.path}/migrations/1000_initial_schema.up.sql')
          .writeAsString(_upSql);
      final ids = await withTestDb<List<String>>((db, _) async {
        final discovered = await MigrationManager(db).discoverIn(tmp.path);
        return discovered.map((m) => m.id).toList();
      });
      expect(ids, ['1000_initial_schema']);
    });

    test('0.1.4 databases adopt the initial migration without re-running it',
        () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      final out = await withTestDb<List<String>>((db, _) async {
        final manager = MigrationManager(db);
        // 0.1.4 applied the baseline under its own id.
        await manager.up(await manager.discoverIn(tmp.path));

        await Directory('${tmp.path}/migrations').create();
        await File('${tmp.path}/migrations/1000_initial_schema.up.sql')
            .writeAsString(_upSql);
        await File('${tmp.path}/migrations/1001_add_col.up.sql').writeAsString(
            'ALTER TABLE widgets ADD COLUMN size INT;');

        final res = await manager.up(await manager.discoverIn(tmp.path));
        return res.applied.map((m) => m.id).toList();
      });
      expect(out, ['1000_initial_schema', '1001_add_col']);
    });
  });
}
