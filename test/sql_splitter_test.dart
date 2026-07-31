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

    test('keeps a -- sequence that appears inside a string literal', () {
      const sql = "INSERT INTO t (cmd) VALUES ('cargo build --release');";
      expect(splitSqlStatements(sql), [
        "INSERT INTO t (cmd) VALUES ('cargo build --release')",
      ]);
    });

    test('does not split on a semicolon inside a string literal', () {
      const sql = "INSERT INTO t (cmd) VALUES ('a; b');";
      expect(splitSqlStatements(sql), ["INSERT INTO t (cmd) VALUES ('a; b')"]);
    });

    test('handles a multi-row insert whose values contain -- and ;', () {
      const sql = '''
-- seed; with a semicolon in the comment
INSERT INTO "applications" ("key", "cmd") VALUES
  ('rust', 'cargo build --release'),
  ('zig', NULL),
  ('sh', 'echo one; echo two');
''';
      expect(splitSqlStatements(sql), [
        'INSERT INTO "applications" ("key", "cmd") VALUES\n'
            "  ('rust', 'cargo build --release'),\n"
            "  ('zig', NULL),\n"
            "  ('sh', 'echo one; echo two')",
      ]);
    });

    test('respects doubled single quotes as an escaped quote', () {
      const sql = "INSERT INTO t (v) VALUES ('it''s; fine --nope');";
      expect(splitSqlStatements(sql), [
        "INSERT INTO t (v) VALUES ('it''s; fine --nope')",
      ]);
    });

    test('respects quoted identifiers containing punctuation', () {
      const sql = 'ALTER TABLE "weird;name--x" ADD COLUMN "a" INT;';
      expect(splitSqlStatements(sql), [
        'ALTER TABLE "weird;name--x" ADD COLUMN "a" INT',
      ]);
    });

    test('keeps dollar-quoted function bodies intact', () {
      const sql = r'''
CREATE FUNCTION touch() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
''';
      final statements = splitSqlStatements(sql);
      expect(statements, hasLength(1));
      expect(statements.single, contains('NEW.updated_at = now();'));
      expect(statements.single, endsWith('LANGUAGE plpgsql'));
    });

    test('keeps tagged dollar quotes intact', () {
      const sql = r"SELECT $tag$ a; b -- c $tag$;";
      expect(splitSqlStatements(sql), [r'SELECT $tag$ a; b -- c $tag$']);
    });

    test(r'does not mistake a $1 placeholder for a dollar quote', () {
      const sql = r'DELETE FROM t WHERE id = $1;UPDATE t SET x = $2;';
      expect(splitSqlStatements(sql), [
        r'DELETE FROM t WHERE id = $1',
        r'UPDATE t SET x = $2',
      ]);
    });

    test('strips block comments, including nested ones', () {
      const sql = '''
/* outer; /* inner; */ still outer; */
SELECT 1;
''';
      expect(splitSqlStatements(sql), ['SELECT 1']);
    });

    test('handles backslash escapes inside E-strings', () {
      const sql = r"INSERT INTO t (v) VALUES (E'a\'; b');";
      expect(splitSqlStatements(sql), [r"INSERT INTO t (v) VALUES (E'a\'; b')"]);
    });

    test('tolerates a trailing statement with no semicolon', () {
      const sql = 'SELECT 1;\nSELECT 2';
      expect(splitSqlStatements(sql), ['SELECT 1', 'SELECT 2']);
    });
  });
}
