library gisila.test.sql_emitter_test;

import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:test/test.dart';

void main() {
  group('SQL emitter foreign-key ordering', () {
    test('up SQL creates tables before enforcing foreign keys', () {
      const yaml = '''
Post:
  columns:
    author:
      type: User
      references: User
      is_null: false
    title:
      type: varchar
      is_null: false

User:
  columns:
    email:
      type: varchar
      is_null: false
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      final createPostIdx = upSql.indexOf('CREATE TABLE "post"');
      final createUserIdx = upSql.indexOf('CREATE TABLE "user"');
      final addFkIdx = upSql.indexOf(
        'ALTER TABLE "post" ADD CONSTRAINT "post_author_fkey"',
      );

      expect(createPostIdx, greaterThanOrEqualTo(0));
      expect(createUserIdx, greaterThanOrEqualTo(0));
      expect(addFkIdx, greaterThanOrEqualTo(0));
      expect(addFkIdx, greaterThan(createPostIdx));
      expect(addFkIdx, greaterThan(createUserIdx));
      expect(
        upSql.contains('CREATE TABLE "post" (\n'
            '  "id" BIGSERIAL PRIMARY KEY,\n'
            '  "author_id" INTEGER NOT NULL,\n'),
        isTrue,
      );
    });

    test('down SQL removes foreign keys before dropping tables', () {
      const yaml = '''
Post:
  columns:
    author:
      type: User
      references: User
    title:
      type: varchar

User:
  columns:
    email:
      type: varchar
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final downSql = emitDownSql(schema);

      final dropFkIdx = downSql.indexOf(
        'ALTER TABLE "post" DROP CONSTRAINT IF EXISTS "post_author_fkey";',
      );
      final dropPostIdx =
          downSql.indexOf('DROP TABLE IF EXISTS "post" CASCADE;');
      final dropUserIdx =
          downSql.indexOf('DROP TABLE IF EXISTS "user" CASCADE;');

      expect(dropFkIdx, greaterThanOrEqualTo(0));
      expect(dropPostIdx, greaterThanOrEqualTo(0));
      expect(dropUserIdx, greaterThanOrEqualTo(0));
      expect(dropFkIdx, lessThan(dropPostIdx));
      expect(dropFkIdx, lessThan(dropUserIdx));
    });
  });
}
