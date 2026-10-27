/// `sslrootcert` trusts its CA for that connection only (ORM-19).
///
/// Needs a TLS Postgres whose certificate is signed by a test CA; see the
/// TLS recipe in HARDENING.md. Set GISILA_TEST_TLS_PORT, GISILA_TEST_TLS_CA
/// (the CA that signed the server) and GISILA_TEST_TLS_OTHER_CA (any other
/// CA). Skipped otherwise.
library gisila.test.tls_root_cert_test;

import 'dart:io';

import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  final port = int.tryParse(env['GISILA_TEST_TLS_PORT'] ?? '');
  final ca = env['GISILA_TEST_TLS_CA'];
  final otherCa = env['GISILA_TEST_TLS_OTHER_CA'];
  final skip = port == null || ca == null || otherCa == null
      ? 'set GISILA_TEST_TLS_PORT, GISILA_TEST_TLS_CA and '
          'GISILA_TEST_TLS_OTHER_CA'
      : false;

  Future<bool> sslWith(String caFile) async {
    final db = await Database.connect(DatabaseConfig(connections: [
      DatabaseConnection(
        name: 'default',
        type: DatabaseType.postgresql,
        host: 'localhost',
        port: port!,
        database: 'postgres',
        username: 'postgres',
        password: 'postgres',
        sslMode: DatabaseSslMode.verifyFull,
        sslRootCert: caFile,
      ),
    ]));
    try {
      final r = await db
          .execute('SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()');
      return r.first[0] as bool;
    } finally {
      await db.close();
    }
  }

  test('each connection trusts only its own CA, in one process', () async {
    expect(await sslWith(ca!), isTrue);
    // With postgres < 3.5.13 the pool's context was dropped and gisila_orm
    // added the CA to the process-wide default context instead, so every
    // later connection trusted the first CA too.
    await expectLater(sslWith(otherCa!), throwsA(anything));
    expect(await sslWith(ca), isTrue);
  }, skip: skip);
}
