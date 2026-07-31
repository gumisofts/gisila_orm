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

      final createPostIdx = upSql.indexOf('CREATE TABLE "posts"');
      final createUserIdx = upSql.indexOf('CREATE TABLE "users"');
      final addFkIdx = upSql.indexOf(
        'ALTER TABLE "posts" ADD CONSTRAINT "posts_author_fkey"',
      );

      expect(createPostIdx, greaterThanOrEqualTo(0));
      expect(createUserIdx, greaterThanOrEqualTo(0));
      expect(addFkIdx, greaterThanOrEqualTo(0));
      expect(addFkIdx, greaterThan(createPostIdx));
      expect(addFkIdx, greaterThan(createUserIdx));
      expect(
        upSql.contains('CREATE TABLE "posts" (\n'
            '  "id" BIGSERIAL PRIMARY KEY,\n'
            '  "author_id" BIGINT NOT NULL,\n'),
        isTrue,
      );
    });

    test(
        'foreign-key and junction columns match the referenced primary '
        "key's actual type and name, not a hardcoded INTEGER/\"id\"", () {
      const yaml = '''
Payment:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
      default: gen_random_uuid()
    amount:
      type: decimal

Callback:
  columns:
    payment:
      type: Payment
      references: Payment
      is_null: false

Tag:
  columns:
    slug:
      type: varchar
      is_primary: true
      is_null: false
    callbacks:
      type: Callback
      many_to_many: true
      references: Callback
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      // FK column takes on the referenced UUID primary key's type.
      expect(upSql, contains('"payment_id" UUID NOT NULL'));
      expect(
        upSql,
        contains(
          'FOREIGN KEY ("payment_id") REFERENCES "payments" ("id")',
        ),
      );

      // Junction table columns match each side's real primary key: an
      // implicit BIGSERIAL id (-> BIGINT) for Callback, and an explicit
      // VARCHAR "slug" primary key for Tag.
      expect(upSql, contains('"callbacks_id" BIGINT NOT NULL'));
      expect(upSql, contains('"tags_id" VARCHAR(255) NOT NULL'));
      expect(
        upSql,
        contains(
          'FOREIGN KEY ("callbacks_id") REFERENCES "callbacks" ("id")',
        ),
      );
      expect(
        upSql,
        contains('FOREIGN KEY ("tags_id") REFERENCES "tags" ("slug")'),
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
        'ALTER TABLE "posts" DROP CONSTRAINT IF EXISTS "posts_author_fkey";',
      );
      final dropPostIdx =
          downSql.indexOf('DROP TABLE IF EXISTS "posts" CASCADE;');
      final dropUserIdx =
          downSql.indexOf('DROP TABLE IF EXISTS "users" CASCADE;');

      expect(dropFkIdx, greaterThanOrEqualTo(0));
      expect(dropPostIdx, greaterThanOrEqualTo(0));
      expect(dropUserIdx, greaterThanOrEqualTo(0));
      expect(dropFkIdx, lessThan(dropPostIdx));
      expect(dropFkIdx, lessThan(dropUserIdx));
    });
  });

  group('SQL emitter schema gap fixes', () {
    test('FK fields already ending in _id do not get a second _id suffix', () {
      const yaml = '''
User:
  columns:
    email:
      type: varchar

Employee:
  columns:
    user_id:
      type: foreign_key
      references: User
      is_null: false
    company_id:
      type: foreign_key
      references: Company
      is_null: false

Company:
  columns:
    name:
      type: varchar
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      expect(upSql, contains('"user_id" BIGINT NOT NULL'));
      expect(upSql, contains('"company_id" BIGINT NOT NULL'));
      expect(upSql, isNot(contains('user_id_id')));
      expect(upSql, isNot(contains('company_id_id')));
      expect(
        upSql,
        contains('FOREIGN KEY ("user_id") REFERENCES "users" ("id")'),
      );
    });

    test('explicit indexes remap logical FK names to physical *_id columns',
        () {
      const yaml = '''
User:
  columns:
    email:
      type: varchar

Book:
  columns:
    title:
      type: varchar

Review:
  columns:
    book:
      type: Book
      references: Book
      is_null: false
    reviewer:
      type: User
      references: User
      is_null: false
  indexes:
    idx_review_book:
      columns: [book]
    idx_review_reviewer:
      columns: [reviewer]
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      expect(
        upSql,
        contains('CREATE INDEX "idx_review_book" ON "reviews" ("book_id");'),
      );
      expect(
        upSql,
        contains(
          'CREATE INDEX "idx_review_reviewer" ON "reviews" ("reviewer_id");',
        ),
      );
      expect(upSql, isNot(contains('ON "reviews" ("book")')));
    });

    test('default: now emits NOW() rather than a quoted string', () {
      const yaml = '''
Company:
  columns:
    name:
      type: varchar
    created_at:
      type: timestamp
      is_null: false
      default: now
    updated_at:
      type: timestamp
      default: NOW
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      expect(upSql, contains('DEFAULT NOW()'));
      expect(upSql, isNot(contains("DEFAULT 'now'")));
      expect(upSql, isNot(contains("DEFAULT 'NOW'")));
    });

    test('varchar max_length is honored in CREATE TABLE', () {
      const yaml = '''
Tag:
  columns:
    slug:
      type: varchar
      max_length: 50
      is_null: false
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      expect(upSql, contains('"slug" VARCHAR(50) NOT NULL'));
      expect(upSql, isNot(contains('VARCHAR(255)')));
    });

    test('unique belongs-to emits UNIQUE on the physical FK column', () {
      const yaml = '''
User:
  columns:
    email:
      type: varchar

Profile:
  columns:
    user:
      type: User
      references: User
      is_null: false
      is_unique: true
      reverse_name: profile
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final upSql = emitUpSql(schema);

      expect(upSql, contains('"user_id" BIGINT NOT NULL UNIQUE'));
    });
  });
}
