/// `DATABASE_URL` parsing and how its TLS settings reach the driver. The
/// connection tests need the docker-compose Postgres on `localhost:5454`,
/// which runs without TLS.
library gisila.test.database_url_test;

import 'package:gisila_orm/gisila.dart';
import 'package:postgres/postgres.dart' show Connection, ConnectionSettings;
import 'package:test/test.dart';

import 'support/test_db.dart';

DatabaseConnection _url(String url) => DatabaseConnection.fromUrl('t', url);

void main() {
  group('credentials', () {
    test('password keeps every ":" after the first', () {
      final c = _url('postgres://app:a:b:c@db:5432/main');
      expect(c.username, 'app');
      expect(c.password, 'a:b:c');
    });

    test('user, password and database are percent-decoded', () {
      final c = _url('postgresql://us%40er:p%40ss%2Fw%3Ad@db/my%20db');
      expect(c.username, 'us@er');
      expect(c.password, 'p@ss/w:d');
      expect(c.database, 'my db');
    });

    test('user/password query parameters override the user info', () {
      final c = _url('postgres://x:y@db/main?user=app&password=s3cret');
      expect(c.username, 'app');
      expect(c.password, 's3cret');
    });

    test('connectionString round-trips awkward credentials', () {
      final c = _url('postgres://us%40er:p%40ss%3Aw@db:6543/main'
          '?sslmode=verify-full');
      final again = _url(c.connectionString);
      expect(again.username, 'us@er');
      expect(again.password, 'p@ss:w');
      expect(again.port, 6543);
      expect(again.effectiveSslMode, DatabaseSslMode.verifyFull);
    });
  });

  group('sslmode', () {
    final cases = {
      'disable': DatabaseSslMode.disable,
      'allow': DatabaseSslMode.prefer,
      'prefer': DatabaseSslMode.prefer,
      'require': DatabaseSslMode.require,
      'verify-ca': DatabaseSslMode.verifyFull,
      'verify-full': DatabaseSslMode.verifyFull,
    };
    for (final e in cases.entries) {
      test('${e.key} → ${e.value.name}', () {
        final c = _url('postgres://u:p@db/main?sslmode=${e.key}');
        expect(c.effectiveSslMode, e.value);
        expect(c.useSSL, e.value != DatabaseSslMode.disable);
      });
    }

    test('no sslmode keeps the old default (no TLS)', () {
      expect(_url('postgres://u:p@db/main').effectiveSslMode,
          DatabaseSslMode.disable);
    });

    test('ssl=true means require', () {
      expect(_url('postgres://u:p@db/main?ssl=true').effectiveSslMode,
          DatabaseSslMode.require);
    });

    test('an unknown sslmode is rejected instead of turning TLS off', () {
      expect(() => _url('postgres://u:p@db/main?sslmode=verify-everything'),
          throwsArgumentError);
    });

    test('sslrootcert is kept; "system" means the default store', () {
      expect(_url('postgres://u:p@db/m?sslrootcert=/etc/ca.pem').sslRootCert,
          '/etc/ca.pem');
      expect(
          _url('postgres://u:p@db/m?sslrootcert=system').sslRootCert, isNull);
    });

    test('YAML ssl_mode and ssl_root_cert', () {
      final c = DatabaseConnection.fromMap('t', {
        'database': 'main',
        'ssl_mode': 'verify-full',
        'ssl_root_cert': '/etc/ca.pem',
      });
      expect(c.effectiveSslMode, DatabaseSslMode.verifyFull);
      expect(c.toMap()['ssl_mode'], 'verify-full');
    });

    test('DATABASE_URL goes through the same parser', () async {
      final config = await DatabaseConfig.fromEnvironment(
        configFile: '/nonexistent/database.yaml',
        envOverrides: {
          'DATABASE_URL': 'postgres://app:a:b@db/main?sslmode=verify-ca',
        },
      );
      final c = config.defaultConnection;
      expect(c.password, 'a:b');
      expect(c.effectiveSslMode, DatabaseSslMode.verifyFull);
    });
  });

  group('against the test server (no TLS)', () {
    late bool hasDb;
    setUpAll(() async => hasDb = await isTestDbAvailable());

    Future<Object?> query(String url) async {
      final db = await Database.connect(DatabaseConfig(
          connections: [DatabaseConnection.fromUrl('default', url)]));
      try {
        return (await db.execute('SELECT current_user')).first.first;
      } finally {
        await db.close();
      }
    }

    test('prefer falls back to plain TCP when the server has no TLS', () async {
      if (!hasDb) return markTestSkipped('No Postgres on localhost:5454');
      expect(
          await query('postgres://postgres:postgres@localhost:5454/postgres'
              '?sslmode=prefer'),
          'postgres');
    });

    test('require does not fall back', () async {
      if (!hasDb) return markTestSkipped('No Postgres on localhost:5454');
      await expectLater(
          query('postgres://postgres:postgres@localhost:5454/postgres'
              '?sslmode=require'),
          throwsA(anything));
    });

    test('a password containing ":" and "@" authenticates', () async {
      if (!hasDb) return markTestSkipped('No Postgres on localhost:5454');
      final admin = await Connection.open(
          Endpoint(
            host: 'localhost',
            port: 5454,
            database: 'postgres',
            username: 'postgres',
            password: 'postgres',
          ),
          settings: const ConnectionSettings(sslMode: SslMode.disable));
      const role = 'gisila_url_test';
      try {
        await admin.execute('DROP ROLE IF EXISTS $role');
        await admin.execute("CREATE ROLE $role LOGIN PASSWORD 'pa:ss@wo/rd'");
        expect(
            await query('postgres://$role:${Uri.encodeComponent('pa:ss@wo/rd')}'
                '@localhost:5454/postgres'),
            role);
      } finally {
        await admin.execute('DROP ROLE IF EXISTS $role');
        await admin.close();
      }
    });
  });
}
