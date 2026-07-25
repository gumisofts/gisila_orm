import 'package:gisila_orm/migrations/migration_manager.dart';
import 'package:test/test.dart';

void main() {
  group('splitSqlStatements', () {
    test('ignores semicolons inside line comments', () {
      const sql = '''
-- Wallet used a raw UUID column named "merchant"; rename to merchant_id.
ALTER TABLE "wallets" RENAME COLUMN "merchant" TO "merchant_id";
''';
      expect(splitSqlStatements(sql), [
        'ALTER TABLE "wallets" RENAME COLUMN "merchant" TO "merchant_id"',
      ]);
    });

    test('skips nested BEGIN/COMMIT wrappers', () {
      const sql = '''
BEGIN;
CREATE TABLE "merchants" ("id" UUID PRIMARY KEY);
COMMIT;
''';
      expect(splitSqlStatements(sql), [
        'CREATE TABLE "merchants" ("id" UUID PRIMARY KEY)',
      ]);
    });
  });
}
