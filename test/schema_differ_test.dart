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
  });
}
