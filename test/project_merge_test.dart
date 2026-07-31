import 'dart:io';

import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/project_codegen.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/migrations/schema_differ.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gisila_project_merge_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('SchemaDefinition.fromProject', () {
    test('resolves cross-file foreign keys', () async {
      await _write(
        tmp,
        'lib/models/user.gisila.yaml',
        '''
User:
  columns:
    email:
      type: varchar
      is_null: false
''',
      );
      await _write(
        tmp,
        'lib/models/post.gisila.yaml',
        '''
Post:
  columns:
    title:
      type: varchar
      is_null: false
    author:
      type: User
      references: User
      reverse_name: posts
''',
      );

      final files = await discoverSchemaFiles(tmp);
      final schema = await SchemaDefinition.fromProject(files);

      expect(schema.modelNames, containsAll(['User', 'Post']));
      final post = schema.getModel('Post')!;
      final author = post.columns.firstWhere((c) => c.name == 'author');
      expect(author.type, ColumnType.foreignKey);
      expect(author.relationship?.references, 'User');
      expect(author.relationship?.reverseName, 'posts');
    });

    test('shares enums declared in another file', () async {
      await _write(
        tmp,
        'lib/models/enums.gisila.yaml',
        '''
enums:
  TeamRole:
    - member
    - admin
''',
      );
      await _write(
        tmp,
        'lib/models/member.gisila.yaml',
        '''
Member:
  columns:
    role:
      type: TeamRole
      is_null: false
''',
      );

      final schema = await SchemaDefinition.fromProject(
        await discoverSchemaFiles(tmp),
      );
      expect(schema.getEnum('TeamRole')?.values, ['member', 'admin']);
      final role = schema
          .getModel('Member')!
          .columns
          .firstWhere((c) => c.name == 'role');
      expect(role.type, ColumnType.enumType);
      expect(role.enumConfig?.enumName, 'TeamRole');
    });

    test('duplicate model across files fails with both paths', () async {
      await _write(
        tmp,
        'lib/models/a.gisila.yaml',
        '''
User:
  columns:
    name:
      type: varchar
''',
      );
      await _write(
        tmp,
        'lib/models/b.gisila.yaml',
        '''
User:
  columns:
    email:
      type: varchar
''',
      );

      final files = await discoverSchemaFiles(tmp);
      await expectLater(
        SchemaDefinition.fromProject(files),
        throwsA(isA<SchemaValidationException>().having(
          (e) => e.errors.any((err) => err.code == 'duplicate_model'),
          'duplicate_model',
          isTrue,
        )),
      );
    });

    test('conflicting enum values across files fail', () async {
      await _write(
        tmp,
        'lib/a.gisila.yaml',
        '''
enums:
  Status:
    - open
    - closed
''',
      );
      await _write(
        tmp,
        'lib/b.gisila.yaml',
        '''
enums:
  Status:
    - open
    - done
''',
      );

      final files = await discoverSchemaFiles(tmp);
      await expectLater(
        SchemaDefinition.fromProject(files),
        throwsA(isA<SchemaValidationException>().having(
          (e) => e.errors.any((err) => err.code == 'duplicate_enum'),
          'duplicate_enum',
          isTrue,
        )),
      );
    });

    test('identical enums in two files are allowed', () async {
      await _write(
        tmp,
        'lib/a.gisila.yaml',
        '''
enums:
  Status:
    - open
    - closed
Foo:
  columns:
    s:
      type: Status
''',
      );
      await _write(
        tmp,
        'lib/b.gisila.yaml',
        '''
enums:
  Status:
    - open
    - closed
Bar:
  columns:
    s:
      type: Status
''',
      );

      final schema = await SchemaDefinition.fromProject(
        await discoverSchemaFiles(tmp),
      );
      expect(schema.enums, hasLength(1));
      expect(schema.modelNames, containsAll(['Foo', 'Bar']));
    });
  });

  group('generateProjectSchema outputs', () {
    test('single-file emits beside source stem', () async {
      await _write(
        tmp,
        'lib/models/blog.gisila.yaml',
        '''
Post:
  columns:
    title:
      type: varchar
      is_null: false
''',
      );

      final result = await generateProjectSchema(tmp);
      expect(result.stem, 'blog');
      expect(result.isMultiFile, isFalse);
      expect(await result.dartFile.exists(), isTrue);
      expect(p.basename(result.dartFile.path), 'blog.gisila.g.dart');
      expect(await result.upSqlFile.exists(), isTrue);
      expect(p.basename(result.upSqlFile.path), 'blog.gisila.up.sql');
      expect(await result.downSqlFile.exists(), isTrue);

      final dart = await result.dartFile.readAsString();
      expect(dart, contains('class Post'));
      expect(emitUpSql(result.schema), contains('CREATE TABLE'));
    });

    test('multi-file emits schema.gisila.* under lib/models', () async {
      await _write(
        tmp,
        'lib/models/user.gisila.yaml',
        '''
User:
  columns:
    email:
      type: varchar
''',
      );
      await _write(
        tmp,
        'lib/models/post.gisila.yaml',
        '''
Post:
  columns:
    title:
      type: varchar
    author:
      type: User
      references: User
      reverse_name: posts
''',
      );

      final result = await generateProjectSchema(tmp);
      expect(result.stem, 'schema');
      expect(result.isMultiFile, isTrue);
      expect(p.basename(result.dartFile.path), 'schema.gisila.g.dart');
      expect(
        p.normalize(result.outputDir.path),
        p.normalize(p.join(tmp.path, 'lib', 'models')),
      );

      final dart = emitDart(result.schema);
      expect(dart, contains('class User'));
      expect(dart, contains('class Post'));
      expect(dart, contains('HasManyRelation'));
    });
  });

  group('merged incremental differ', () {
    test('uses project snapshot once for multi-file schema', () async {
      await _write(
        tmp,
        'lib/models/user.gisila.yaml',
        '''
User:
  columns:
    email:
      type: varchar
''',
      );
      await _write(
        tmp,
        'lib/models/post.gisila.yaml',
        '''
Post:
  columns:
    title:
      type: varchar
    author:
      type: User
      references: User
''',
      );

      final first = await generateProjectSchema(tmp);
      expect(
        await generateProjectIncrementalMigration(tmp, schema: first.schema),
        isNull,
      );

      final snapshot = File(p.join(tmp.path, projectSnapshotRelativePath));
      expect(await snapshot.exists(), isTrue);

      // Evolve: add a column on User.
      await _write(
        tmp,
        'lib/models/user.gisila.yaml',
        '''
User:
  columns:
    email:
      type: varchar
    bio:
      type: text
      is_null: true
''',
      );

      final second = await generateProjectSchema(tmp);
      final migrationName = await generateProjectIncrementalMigration(
        tmp,
        schema: second.schema,
      );
      expect(migrationName, 'auto_project_changes');

      final migDir = Directory(p.join(tmp.path, 'lib', 'models', 'migrations'));
      final migFiles = await migDir
          .list()
          .where((e) => e.path.endsWith('.up.sql'))
          .toList();
      expect(migFiles, hasLength(1));
      final up = await File(migFiles.first.path).readAsString();
      expect(up, contains('bio'));
    });

    test('emitSchemaYaml round-trips for SchemaDiffer', () async {
      final schema = SchemaDefinition.fromYaml('''
enums:
  Role:
    - a
    - b
User:
  columns:
    role:
      type: Role
    name:
      type: varchar
      is_null: false
''');
      final yaml = emitSchemaYaml(schema);
      final reloaded = SchemaDefinition.fromYaml(yaml);
      final diff = SchemaDiffer().compareSchemas(schema, reloaded);
      expect(diff.isEmpty, isTrue);
    });
  });
}

Future<File> _write(Directory root, String relative, String contents) async {
  final file = File(p.join(root.path, relative));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
  return file;
}
