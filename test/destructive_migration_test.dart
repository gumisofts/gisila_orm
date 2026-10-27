import 'dart:io';

import 'package:gisila_orm/generators/project_codegen.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/migrations/schema_differ.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

SchemaDiff _diff(String oldYaml, String newYaml) =>
    SchemaDiffer().compareSchemas(
        SchemaDefinition.fromYaml(oldYaml), SchemaDefinition.fromYaml(newYaml));

String _user(String columns) => 'User:\n  columns:\n$columns';

const _name = '    name:\n      type: varchar\n';
const _bio = '    bio:\n      type: text\n';
const _age = '    age:\n      type: integer\n';

Future<List<String>> _sqlFiles(Directory dir) async => [
      for (final f in await dir.list().toList())
        if (f is File && f.path.endsWith('.sql')) await f.readAsString()
    ];

void main() {
  group('destructive classification', () {
    test('dropped columns and tables are destructive', () {
      final col = _diff(_user(_name + _bio + _age), _user(_name + _age));
      expect(
          col.destructiveChanges.map((c) => c.type), [ChangeType.dropColumn]);

      final table =
          _diff('${_user(_name)}Post:\n  columns:\n$_name', _user(_name));
      expect(
          table.destructiveChanges.map((c) => c.type), [ChangeType.dropTable]);
    });

    test('adding a column or index is not destructive', () {
      final d = _diff(_user(_name), _user(_name + _age));
      expect(d.destructiveChanges, isEmpty);
      expect(d.hasDestructiveChanges, isFalse);
    });

    test('widening types is not destructive, narrowing is', () {
      String typed(String type) => _user('    n:\n      type: $type\n');
      expect(
          _diff(typed('integer'), typed('bigint')).destructiveChanges, isEmpty);
      expect(
          _diff(typed('varchar'), typed('text')).destructiveChanges, isEmpty);
      expect(_diff(typed('bigint'), typed('integer')).destructiveChanges,
          hasLength(1));
      expect(_diff(typed('text'), typed('integer')).destructiveChanges,
          hasLength(1));
    });

    test('a removed enum is dropped after the column that used it', () {
      const old = '''
enums:
  Mood:
    - happy
    - sad

User:
  columns:
    name:
      type: varchar
    mood:
      type: Mood
''';
      final d = _diff(old, _user(_name));
      final up = d.operations.map((o) => o.upSql).toList();
      final dropCol = up.indexWhere((s) => s.contains('DROP COLUMN'));
      final dropType = up.indexWhere((s) => s.startsWith('DROP TYPE'));
      expect(dropCol, isNonNegative);
      expect(dropType, greaterThan(dropCol));
    });

    test('a guessed rename is flagged but not destructive', () {
      final d = _diff(_user(_bio), _user('    about:\n      type: text\n'));
      expect(d.guessedRenames, hasLength(1));
      expect(d.destructiveChanges, isEmpty);
    });
  });

  group('generateMigrationFile', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('gq_destr_'));
    tearDown(() => tmp.delete(recursive: true));

    test('refuses a destructive diff and writes nothing', () async {
      final d = _diff(_user(_name + _age), _user(_name));
      await expectLater(
        SchemaDiffer().generateMigrationFile(d, tmp.path, 'drop_age'),
        throwsA(isA<DestructiveMigrationException>()
            .having((e) => e.toString(), 'message', contains('users.age'))),
      );
      expect(await _sqlFiles(tmp), isEmpty);
    });

    test('writes it with allowDestructive and marks the step', () async {
      final d = _diff(_user(_name + _age), _user(_name));
      await SchemaDiffer().generateMigrationFile(d, tmp.path, 'drop_age',
          allowDestructive: true);
      final up = (await _sqlFiles(tmp)).firstWhere((s) => s.contains('DROP'));
      expect(up, contains('-- DESTRUCTIVE'));
    });

    test('comments guessed renames without semicolons', () async {
      final d = _diff(_user(_bio), _user('    about:\n      type: text\n'));
      await SchemaDiffer().generateMigrationFile(d, tmp.path, 'rename');
      final up =
          (await _sqlFiles(tmp)).firstWhere((s) => s.contains('-- Migration:'));
      final comments =
          up.split('\n').where((l) => l.startsWith('-- GUESSED RENAME'));
      expect(comments, isNotEmpty);
      expect(up.split('\n').where((l) => l.startsWith('--')).join(),
          isNot(contains(';')));
    });
  });

  test('project codegen keeps the snapshot when it refuses', () async {
    final root = await Directory.systemTemp.createTemp('gq_destr_proj_');
    try {
      final schemaFile =
          File(p.join(root.path, 'lib', 'models', 'user.gisila.yaml'));
      await schemaFile.create(recursive: true);
      await schemaFile.writeAsString(_user(_name + _age));
      await generateProjectIncrementalMigration(root);
      final snapshot = File(p.join(root.path, projectSnapshotRelativePath));
      final before = await snapshot.readAsString();

      await schemaFile.writeAsString(_user(_name));
      await expectLater(generateProjectIncrementalMigration(root),
          throwsA(isA<DestructiveMigrationException>()));
      expect(await snapshot.readAsString(), before);

      final name = await generateProjectIncrementalMigration(root,
          allowDestructive: true);
      expect(name, 'auto_project_changes');
      expect(await snapshot.readAsString(), isNot(before));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
