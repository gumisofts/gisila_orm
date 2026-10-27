/// Upsert and query observation against Postgres on localhost:5454
/// (ORM-17). Skipped when it isn't reachable.
library;

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

Map<String, dynamic> _row(Map<String, dynamic> r) => r;

const _people = TableMeta<Map<String, dynamic>>(
  tableName: 'upsert_people',
  columnNames: ['id', 'email', 'name'],
  fromRow: _row,
);

void main() {
  late bool hasDb;
  setUpAll(() async => hasDb = await isTestDbAvailable());

  test('upsert inserts, then updates in place, and the observer sees it',
      () async {
    if (!hasDb) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    final seen = <String>[];
    final slow = <String>[];
    final db = await Database.connect(
      DatabaseConfig(connections: [
        DatabaseConnection(
          name: 'default',
          type: DatabaseType.postgresql,
          host: 'localhost',
          port: 5454,
          database: 'postgres',
          username: 'postgres',
          password: 'postgres',
          maxConnections: 2,
        ),
      ]),
      onQuery: (sql, params, elapsed, error) {
        seen.add(error == null ? sql : 'ERROR $sql');
        slowQueryLogger(Duration.zero, slow.add)(sql, params, elapsed, error);
      },
    );
    addTearDown(db.close);
    final c = db.context();
    await c.execute('DROP TABLE IF EXISTS upsert_people');
    await c.execute('CREATE TABLE upsert_people (id serial PRIMARY KEY, '
        'email text NOT NULL UNIQUE, name text NOT NULL)');
    addTearDown(() => c.execute('DROP TABLE IF EXISTS upsert_people'));

    Future<Map<String, dynamic>> upsert(String name) => Query(_people)
        .insert({'email': 'ada@x.io', 'name': name}).onConflictDoUpdate(
            ['email']).one(c);

    final first = await upsert('Ada');
    final second = await upsert('Ada Lovelace');
    expect(second['id'], first['id']);
    expect(second['name'], 'Ada Lovelace');

    final skipped = await Query(_people)
        .insert({'email': 'ada@x.io', 'name': 'ignored'}).onConflictDoNothing(
            ['email']).run(c);
    expect(skipped, isEmpty);

    await db.transaction((tx) => tx.execute('SELECT 1'));
    await expectLater(
        c.execute('SELECT * FROM missing_table'), throwsA(anything));

    expect(seen.where((s) => s.contains('ON CONFLICT')), hasLength(3));
    expect(seen, contains('SELECT 1'));
    expect(seen, contains('ERROR SELECT * FROM missing_table'));
    expect(slow.any((m) => m.startsWith('query failed')), isTrue);
  });
}
