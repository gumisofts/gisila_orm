/// New tables added by a later migration must get the same foreign keys,
/// indexes and junction tables as a fresh install. The SQL checks always
/// run; the apply/rollback check needs the docker-compose Postgres on
/// `localhost:5454`.
library gisila.test.new_table_migration_test;

import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/gisila.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

const _before = '''
User:
  columns:
    name:
      type: varchar
''';

const _after = '''
User:
  columns:
    name:
      type: varchar
Post:
  columns:
    title:
      type: varchar
      is_index: true
    slug:
      type: varchar
    author:
      type: foreign_key
      references: User
      is_null: false
      on_delete: CASCADE
    tags:
      type: Tag
      many_to_many: true
      references: Tag
  indexes:
    idx_posts_slug:
      columns: [slug]
      unique: true
Tag:
  columns:
    label:
      type: varchar
''';

SchemaDiff _diff() => SchemaDiffer().compareSchemas(
    SchemaDefinition.fromYaml(_before), SchemaDefinition.fromYaml(_after));

void main() {
  test('new tables get their FKs, indexes and junction table', () {
    final up = _diff().operations.map((o) => o.upSql).join('\n');
    expect(up, contains('FOREIGN KEY ("author_id") REFERENCES "users"'));
    expect(up, contains('ON DELETE CASCADE'));
    expect(up, contains('CREATE INDEX "idx_posts_title" ON "posts"'));
    expect(up, contains('CREATE UNIQUE INDEX "idx_posts_slug" ON "posts"'));
    expect(up, contains('CREATE TABLE "posts_tags"'));
  });

  test('FKs and junctions come after every CREATE TABLE', () {
    final ops = _diff().operations;
    int indexOf(bool Function(MigrationOperation) f) => ops.indexWhere(f);
    final lastCreate = ops.lastIndexWhere(
        (o) => o.change.type == ChangeType.createTable &&
            o.change.tableName != 'posts_tags');
    expect(indexOf((o) => o.change.type == ChangeType.addForeignKey),
        greaterThan(lastCreate));
    expect(indexOf((o) => o.change.tableName == 'posts_tags'),
        greaterThan(lastCreate));
  });

  test('removing a many-to-many drops its junction first', () {
    final diff = SchemaDiffer().compareSchemas(
        SchemaDefinition.fromYaml(_after), SchemaDefinition.fromYaml(_before));
    final drops = diff.operations
        .where((o) => o.change.type == ChangeType.dropTable)
        .map((o) => o.change.tableName)
        .toList();
    expect(drops.first, 'posts_tags');
    expect(diff.destructiveChanges.map((c) => c.tableName),
        contains('posts_tags'));
  });

  test('migrating up matches a fresh install, and rolls back', () async {
    if (!await isTestDbAvailable()) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    final ops = _diff().operations;
    Future<Set<String>> shape(Database db) async {
      final rows = await db.execute('''
        SELECT 'c:' || conname FROM pg_constraint c
          JOIN pg_namespace n ON n.oid = c.connamespace
          WHERE n.nspname = current_schema() AND contype IN ('f', 'p', 'u')
        UNION ALL
        SELECT 'i:' || indexname FROM pg_indexes
          WHERE schemaname = current_schema()
        UNION ALL
        SELECT 't:' || table_name FROM information_schema.tables
          WHERE table_schema = current_schema()
            AND table_name <> 'gisila_migrations'
      ''');
      return {for (final r in rows) r[0] as String};
    }

    final fresh = await withTestDb<Set<String>>((db, _) async {
      await MigrationManager(db).up([
        Migration(
            id: '1_all', upSql: emitUpSql(SchemaDefinition.fromYaml(_after))),
      ]);
      return shape(db);
    });

    final migrated = await withTestDb<(Set<String>, Set<String>)>(
        (db, _) async {
      final manager = MigrationManager(db);
      final base = Migration(
          id: '1_base',
          upSql: emitUpSql(SchemaDefinition.fromYaml(_before)));
      final change = Migration(
        id: '2_posts',
        upSql: ops.map((o) => o.upSql).join('\n'),
        downSql: ops.reversed.map((o) => o.downSql).join('\n'),
      );
      await manager.up([base]);
      await manager.up([base, change]);
      final after = await shape(db);
      await manager.down(discovered: [base, change], steps: 1);
      return (after, await shape(db));
    });

    expect(migrated!.$1, fresh);
    expect(migrated.$2.where((s) => s.startsWith('t:')), {'t:users'});
  });
}
