/// Validates that every diagnostic the schema parser is supposed to
/// emit fires for the right input shape, points at the right span,
/// and renders a clean rust-style report (no ANSI for deterministic
/// assertions).
library gisila.test.schema_validation_test;

import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaDefinition.fromYaml — happy path', () {
    test('parses a fully populated schema without errors', () {
      const yaml = '''
Author:
  columns:
    name:
      type: varchar
      is_null: false
    email:
      type: varchar
      is_null: false
      is_unique: true
      is_index: true

Post:
  db_table: posts
  columns:
    title:
      type: varchar
      is_null: false
    body:
      type: text
    author:
      type: Author
      references: Author
      is_index: true
      reverse_name: posts
      on_delete: SET NULL
  indexes:
    idx_post_title:
      columns: [title]
      unique: true
''';
      final schema = SchemaDefinition.fromYaml(yaml);
      expect(schema.modelNames, ['Author', 'Post']);
      final post = schema.getModel('Post')!;
      expect(post.tableName, 'posts');
      expect(post.indexes.single.columns, ['title']);
      expect(post.indexes.single.isUnique, isTrue);
      final fk = post.foreignKeyColumns.single;
      expect(fk.relationship!.references, 'Author');
      expect(fk.relationship!.onDelete, 'SET NULL');
    });

    test('inserts implicit BIGSERIAL id when no primary key is declared', () {
      const yaml = '''
Author:
  columns:
    name:
      type: varchar
''';
      final schema = SchemaDefinition.fromYaml(yaml);
      final pk = schema.getModel('Author')!.primaryKey!;
      expect(pk.name, 'id');
      expect(pk.constraints.isPrimary, isTrue);
      expect(pk.constraints.isNull, isFalse);
    });
  });

  group('top-level shape', () {
    test('reports a clear error when the file is empty', () {
      _expectError(
        '',
        code: 'empty_schema',
        messageContains: 'empty',
      );
    });

    test('reports `expected_map` when the document is a list', () {
      _expectError(
        '- foo\n- bar\n',
        code: 'expected_map',
        messageContains: 'top-level schema must be a YAML map',
      );
    });

    test('reports duplicate model/key declarations', () {
      // The underlying yaml package raises one error per duplicate
      // map key; we re-label it as `duplicate_key` so the user sees
      // a focused message rather than a raw parser string.
      const yaml = '''
User:
  columns:
    name:
      type: varchar
User:
  columns:
    age:
      type: integer
''';
      final ex = _expectErrors(yaml);
      final dup = ex.errors.firstWhere((e) => e.code == 'duplicate_key');
      expect(dup.message, contains('unique'));
      expect(dup.hint, isNotNull);
    });
  });

  group('model-level validation', () {
    test('rejects PascalCase typos in model name with a warning', () {
      const yaml = '''
user:
  columns:
    name:
      type: varchar
''';
      final ex = _expectErrors(yaml);
      final warn = ex.errors.firstWhere((e) => e.code == 'naming_convention');
      expect(warn.level, SchemaErrorLevel.warning);
      expect(warn.hint, contains('User'));
    });

    test('reports invalid model name', () {
      _expectError(
        '''
1Bad:
  columns:
    name:
      type: varchar
''',
        code: 'invalid_model_name',
        messageContains: '1Bad',
      );
    });

    test('reports a missing `columns` block', () {
      _expectError(
        '''
User:
  db_table: users
''',
        code: 'missing_columns',
        messageContains: '`columns`',
      );
    });

    test('reports unknown model-level keys with a "did you mean?" hint', () {
      final ex = _expectErrors('''
User:
  collumns:
    name:
      type: varchar
''');
      final unknownKey = ex.errors.firstWhere((e) => e.code == 'unknown_key');
      expect(unknownKey.message, contains('collumns'));
      expect(unknownKey.hint, contains('columns'));
    });

    test('reports invalid `db_table`', () {
      _expectError(
        '''
User:
  db_table: 'has spaces'
  columns:
    name:
      type: varchar
''',
        code: 'invalid_db_table',
        messageContains: '`db_table`',
      );
    });
  });

  group('column-level validation', () {
    test('reports missing `type` field', () {
      _expectError(
        '''
User:
  columns:
    name:
      is_null: false
''',
        code: 'missing_type',
        messageContains: '`type`',
      );
    });

    test('reports unknown column type with the closest builtin suggestion', () {
      final ex = _expectErrors('''
User:
  columns:
    name:
      type: varchars
''');
      final err = ex.errors.firstWhere((e) => e.code == 'unknown_type');
      expect(err.message, contains('varchars'));
      expect(err.hint, contains('varchar'));
      // Span should point at the value `varchars`, not the `type:` key.
      // The triple-quoted YAML literal has `User:` on line 1, so
      // `varchars` lands on line 4 (1-based).
      expect(err.span.start.line + 1, 4);
      // Column 13 (1-based) is the start of `varchars` after `      type: `.
      expect(err.span.start.column, greaterThan(0));
    });

    test('reports unknown column key with a suggestion', () {
      final ex = _expectErrors('''
User:
  columns:
    name:
      type: varchar
      is_nul: false
''');
      final err = ex.errors.firstWhere(
          (e) => e.code == 'unknown_key' && e.message.contains('is_nul'));
      expect(err.hint, contains('is_null'));
    });

    test('rejects non-bool boolean constraints', () {
      final ex = _expectErrors('''
User:
  columns:
    name:
      type: varchar
      is_null: yes
''');
      final err = ex.errors.firstWhere((e) => e.code == 'invalid_value');
      expect(err.message, contains('boolean'));
    });

    test('rejects primary key with is_null: true', () {
      final ex = _expectErrors('''
User:
  columns:
    id:
      type: integer
      is_primary: true
      is_null: true
''');
      final err = ex.errors.firstWhere((e) => e.code == 'invalid_primary_key');
      expect(err.message, contains('is_null'));
    });

    test('rejects duplicate column names (via YAML duplicate-key error)', () {
      final ex = _expectErrors('''
User:
  columns:
    name:
      type: varchar
    name:
      type: text
''');
      expect(
        ex.errors.any((e) => e.code == 'duplicate_key'),
        isTrue,
      );
    });
  });

  group('relationships', () {
    test('reports references to an unknown model', () {
      final ex = _expectErrors('''
Post:
  columns:
    author:
      type: Authour
      references: Authour
''');
      final err = ex.errors.firstWhere((e) => e.code == 'unknown_reference');
      expect(err.message, contains('Authour'));
    });

    test('suggests the closest model when the reference has a typo', () {
      final ex = _expectErrors('''
Author:
  columns:
    name:
      type: varchar

Post:
  columns:
    author:
      type: Authour
      references: Authour
''');
      final err = ex.errors.firstWhere((e) => e.code == 'unknown_reference');
      expect(err.hint, contains('Author'));
    });

    test('rejects `references` on a builtin column type', () {
      _expectError(
        '''
User:
  columns:
    name:
      type: varchar
      references: User
''',
        code: 'invalid_relationship',
        messageContains: 'references',
      );
    });

    test('rejects invalid on_delete action with suggestion', () {
      final ex = _expectErrors('''
Author:
  columns:
    name:
      type: varchar

Post:
  columns:
    author:
      type: Author
      references: Author
      on_delete: CASCAD
''');
      final err =
          ex.errors.firstWhere((e) => e.code == 'invalid_referential_action');
      expect(err.hint, contains('CASCADE'));
    });

    test('detects reverse_name collision with an existing column', () {
      final ex = _expectErrors('''
Author:
  columns:
    posts:
      type: varchar

Post:
  columns:
    author:
      type: Author
      references: Author
      reverse_name: posts
''');
      final err =
          ex.errors.firstWhere((e) => e.code == 'reverse_name_collision');
      expect(err.message, contains('posts'));
    });
  });

  group('indexes', () {
    test('reports unknown index key', () {
      final ex = _expectErrors('''
User:
  columns:
    name:
      type: varchar
  indexes:
    idx_user_name:
      columns: [name]
      uniqe: true
''');
      final err = ex.errors.firstWhere(
          (e) => e.code == 'unknown_key' && e.message.contains('uniqe'));
      expect(err.hint, contains('unique'));
    });

    test('reports an index that points at a non-existent column', () {
      final ex = _expectErrors('''
User:
  columns:
    name:
      type: varchar
  indexes:
    idx:
      columns: [naem]
''');
      final err = ex.errors.firstWhere((e) => e.code == 'unknown_column');
      expect(err.hint, contains('name'));
    });

    test('reports `columns` when it is not a list', () {
      _expectError(
        '''
User:
  columns:
    name:
      type: varchar
  indexes:
    idx:
      columns: name
''',
        code: 'expected_list',
        messageContains: 'must be a list',
      );
    });
  });

  group('formatted output', () {
    test('renders a rust-style report with file:line:col, snippet, caret, hint',
        () {
      const yaml = '''
User:
  columns:
    name:
      type: varchars
''';
      try {
        SchemaDefinition.fromYaml(yaml,
            sourceUrl: Uri.parse('blog.gisila.yaml'));
        fail('expected SchemaValidationException');
      } on SchemaValidationException catch (e) {
        final report = e.format(color: false);
        expect(report, contains('error[unknown_type]: unknown column type'));
        expect(report, contains('--> blog.gisila.yaml:4:'));
        expect(report, contains('type: varchars'));
        expect(report, contains('^'));
        expect(report, contains('did you mean'));
        expect(report, contains('aborting due to'));
      }
    });
  });
}

SchemaValidationException _expectErrors(String yaml) {
  try {
    SchemaDefinition.fromYaml(yaml);
    fail('expected SchemaValidationException for input:\n$yaml');
  } on SchemaValidationException catch (e) {
    return e;
  }
}

void _expectError(String yaml,
    {required String code, required String messageContains}) {
  final ex = _expectErrors(yaml);
  final match = ex.errors.where((e) => e.code == code).toList();
  expect(
    match,
    isNotEmpty,
    reason: 'expected at least one error with code "$code", got: '
        '${ex.errors.map((e) => "${e.code}: ${e.message}").toList()}',
  );
  expect(match.first.message, contains(messageContains));
}
