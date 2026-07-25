library gisila.test.schema_differ_test;

import 'dart:io';

import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/migrations/schema_differ.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaDiffer incremental generation', () {
    test('detects a simple column rename', () {
      const oldYaml = '''
User:
  columns:
    name:
      type: varchar
      is_null: false
''';
      const newYaml = '''
User:
  columns:
    full_name:
      type: varchar
      is_null: false
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      expect(
        diff.changes.any((c) => c.type == ChangeType.renameColumn),
        isTrue,
      );
      expect(
        diff.operations.any(
            (o) => o.upSql.contains('RENAME COLUMN "name" TO "full_name"')),
        isTrue,
      );
    });

    test('writes discovered migration pair as .up.sql/.down.sql', () async {
      const oldYaml = '''
User:
  columns:
    name:
      type: varchar
''';
      const newYaml = '''
User:
  columns:
    name:
      type: varchar
    age:
      type: integer
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final differ = SchemaDiffer();
      final diff = differ.compareSchemas(oldSchema, newSchema);
      expect(diff.isNotEmpty, isTrue);

      final tmp = await Directory.systemTemp.createTemp('gisila_schema_diff_');
      try {
        await differ.generateMigrationFile(diff, tmp.path, 'add_age');

        final entries = await tmp.list().toList();
        final names = entries
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .toList();

        expect(names.any((n) => n.endsWith('_add_age.up.sql')), isTrue);
        expect(names.any((n) => n.endsWith('_add_age.down.sql')), isTrue);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test(
        'adding a belongs-to column matches the type/name of the '
        "referenced model's actual primary key", () {
      const oldYaml = '''
Payment:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false

Callback:
  columns:
    payload:
      type: json
''';
      const newYaml = '''
Payment:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false

Callback:
  columns:
    payload:
      type: json
    payment:
      type: Payment
      references: Payment
      is_null: false
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final addColumn = diff.operations
          .map((o) => o.upSql)
          .firstWhere((s) => s.contains('ADD COLUMN "payment_id"'));
      expect(addColumn, contains('"payment_id" UUID NOT NULL'));

      final addFk = diff.operations
          .map((o) => o.upSql)
          .firstWhere((s) => s.contains('ADD CONSTRAINT'));
      expect(
        addFk,
        contains('FOREIGN KEY ("payment_id") REFERENCES "payments" ("id")'),
      );
    });

    test(
        'a brand new table gets an auto-incrementing BIGSERIAL id, not a '
        'plain INTEGER', () {
      const oldYaml = '''
User:
  columns:
    name:
      type: varchar
''';
      const newYaml = '''
User:
  columns:
    name:
      type: varchar

Post:
  columns:
    title:
      type: varchar
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final createTable = diff.operations
          .map((o) => o.upSql)
          .firstWhere((s) => s.contains('CREATE TABLE "posts"'));
      expect(createTable, contains('"id" BIGSERIAL PRIMARY KEY'));
    });

    test('add index quotes reserved-word columns', () {
      const oldYaml = '''
Review:
  db_table: reviews
  columns:
    id:
      type: integer
      is_primary: true
      is_null: false
''';
      const newYaml = '''
Review:
  db_table: reviews
  columns:
    id:
      type: integer
      is_primary: true
      is_null: false
    desc:
      type: text
  indexes:
    idx_review_desc:
      columns:
        - desc
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final addIndex = diff.operations
          .where((o) => o.upSql.contains('CREATE INDEX'))
          .map((o) => o.upSql)
          .firstWhere((s) => s.contains('idx_review_desc'), orElse: () => '');

      expect(
        addIndex,
        'CREATE INDEX "idx_review_desc" ON "reviews" ("desc");',
      );
    });

    test('SET DEFAULT routes aliases through DefaultEngine', () {
      const oldYaml = '''
Company:
  columns:
    name:
      type: varchar
''';
      const newYaml = '''
Company:
  columns:
    name:
      type: varchar
    created_at:
      type: timestamp
      default: now
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final addColumn = diff.operations
          .map((o) => o.upSql)
          .firstWhere((s) => s.contains('ADD COLUMN "created_at"'));
      expect(addColumn, contains('DEFAULT NOW()'));
      expect(addColumn, isNot(contains("DEFAULT now")));
    });

    test(
        'promoting a UUID column to a foreign_key does not emit '
        'ALTER … TYPE INTEGER', () {
      const oldYaml = '''
Merchant:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
    name:
      type: varchar
      is_null: false

ApiKey:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
    merchant_id:
      type: uuid
      is_null: false
      is_index: true
''';
      const newYaml = '''
Merchant:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
    name:
      type: varchar
      is_null: false

ApiKey:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
    merchant_id:
      type: foreign_key
      references: Merchant
      is_null: false
      is_index: true
      on_delete: RESTRICT
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final upSql = diff.operations.map((o) => o.upSql).join('\n');
      expect(upSql, isNot(contains('TYPE INTEGER')));
      expect(upSql, isNot(contains('TYPE UUID')));
      expect(
        upSql,
        contains(
          'FOREIGN KEY ("merchant_id") REFERENCES "merchants" ("id") '
          'ON DELETE RESTRICT',
        ),
      );
      expect(
        diff.changes.any((c) => c.type == ChangeType.modifyColumn),
        isFalse,
      );
      expect(
        diff.changes.any((c) => c.type == ChangeType.addForeignKey),
        isTrue,
      );
    });

    test(
        'promoting a scalar column to a belongs-to FK renames the '
        'physical column and keeps the UUID type', () {
      const oldYaml = '''
Merchant:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false

Wallet:
  columns:
    merchant:
      type: uuid
      is_null: false
      is_unique: true
''';
      const newYaml = '''
Merchant:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false

Wallet:
  columns:
    merchant:
      type: Merchant
      references: Merchant
      is_null: false
      is_unique: true
      on_delete: RESTRICT
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final upSql = diff.operations.map((o) => o.upSql).join('\n');
      expect(
        upSql,
        contains('RENAME COLUMN "merchant" TO "merchant_id"'),
      );
      expect(upSql, isNot(contains('TYPE INTEGER')));
      expect(
        upSql,
        contains(
          'FOREIGN KEY ("merchant_id") REFERENCES "merchants" ("id") '
          'ON DELETE RESTRICT',
        ),
      );
      expect(
        diff.changes.any((c) => c.type == ChangeType.modifyColumn),
        isFalse,
      );
    });

    test('indexes on FK logical names remap to physical columns', () {
      const oldYaml = '''
User:
  columns:
    email:
      type: varchar

Post:
  columns:
    author:
      type: User
      references: User
''';
      const newYaml = '''
User:
  columns:
    email:
      type: varchar

Post:
  columns:
    author:
      type: User
      references: User
  indexes:
    idx_post_author:
      columns: [author]
''';

      final oldSchema = SchemaDefinition.fromYaml(oldYaml);
      final newSchema = SchemaDefinition.fromYaml(newYaml);
      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);

      final addIndex = diff.operations
          .map((o) => o.upSql)
          .firstWhere((s) => s.contains('idx_post_author'));
      expect(
        addIndex,
        'CREATE INDEX "idx_post_author" ON "posts" ("author_id");',
      );
    });
  });
}
