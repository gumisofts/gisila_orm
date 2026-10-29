/// `package:gisila_orm/web.dart`: the database provider and the Postgres
/// error mapper. The integration part needs Postgres on `localhost:5454`.
library;

import 'package:gisila/gisila.dart' show HttpException;
import 'package:gisila_orm/gisila.dart';
import 'package:gisila_orm/web.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

HttpException? _map(Object e) =>
    const PostgresDbErrorMapper().map(e, StackTrace.current);

void main() {
  group('PostgresDbErrorMapper', () {
    test('unique violation: 409 naming the columns, never the values', () {
      final e = _map(const PostgresUniqueViolationException(
        'duplicate key value violates unique constraint "users_email_key"',
        sqlState: '23505',
        details: {
          'detail': 'Key (email)=(ann@example.com) already exists.',
          'constraint': 'users_email_key',
        },
      ))!;
      expect(e.statusCode, 409);
      expect(e.code, 'unique_violation');
      expect(e.message, '"email" is already taken.');
      expect(e.details, {
        'fields': ['email']
      });
      expect(e.toJson().toString(), isNot(contains('ann@example.com')));
    });

    test('multi-column keys and missing details', () {
      final multi = _map(const PostgresUniqueViolationException('dup',
          details: {'detail': 'Key (org_id, "slug")=(1, x) already exists.'}))!;
      expect(multi.message, '"org_id", "slug" are already taken.');
      final bare = _map(const PostgresUniqueViolationException('dup'))!;
      expect(bare.message, 'A record with this value already exists.');
      expect(bare.details, isNull);
    });

    test('other constraint and data errors', () {
      expect(
          _map(const PostgresNotNullViolationException('null',
                  details: {'column': 'name'}))!
              .message,
          '"name" is required.');
      final fk = _map(const PostgresForeignKeyViolationException('fk',
          details: {'detail': 'Key (owner_id)=(99) is not present.'}))!;
      expect([fk.statusCode, fk.code], [400, 'foreign_key_violation']);
      expect(fk.message, isNot(contains('99')));
      expect(_map(const PostgresCheckViolationException('chk'))!.code,
          'check_violation');
      expect(_map(const PostgresNumericValueOutOfRangeException('big'))!.code,
          'invalid_value');
      final down = _map(const PostgresConnectionException('gone'))!;
      expect([down.statusCode, down.code], [503, 'database_unavailable']);
    });

    test('leaves anything else to the 500 handler', () {
      expect(_map(StateError('x')), isNull);
      expect(_map(const PostgresUndefinedTableException('no table')), isNull);
    });
  });

  group('against Postgres', () {
    late bool hasDb;
    setUpAll(() async => hasDb = await isTestDbAvailable());

    test('a real duplicate maps without the value', () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      final mapped = await withTestDb<HttpException?>((db, _) async {
        await db.execute(
            'CREATE TABLE people (id SERIAL PRIMARY KEY, email TEXT UNIQUE)');
        await db.execute("INSERT INTO people (email) VALUES ('ann@x.io')");
        try {
          await db.execute("INSERT INTO people (email) VALUES ('ann@x.io')");
        } catch (e) {
          return _map(e);
        }
        return null;
      });
      expect(mapped, isNotNull);
      expect(mapped!.code, 'unique_violation');
      expect(mapped.message, '"email" is already taken.');
      expect(mapped.toJson().toString(), isNot(contains('ann@x.io')));
    });

    test('the provider reports health and closes the pool on dispose',
        () async {
      if (!hasDb) {
        markTestSkipped('No Postgres reachable on localhost:5454');
        return;
      }
      await withTestDb<void>((db, _) async {
        final shared = GisilaOrmDatabaseProvider(db, closeOnDispose: false);
        expect(await shared.isHealthy(), isTrue);
        await shared.dispose();
        expect(await shared.isHealthy(), isTrue, reason: 'not owned');

        final owned = GisilaOrmDatabaseProvider(db);
        await owned.dispose();
        expect(await owned.isHealthy(), isFalse);
        // A closed database refuses work instead of reconnecting.
        expect(() => db.execute('SELECT 1'), throwsStateError);
        await db.close(); // closing again is harmless
      });
    });
  });
}
