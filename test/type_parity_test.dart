library gisila.test.type_parity_test;

import 'package:gisila_orm/database/postgres/types/geometrics.dart';
import 'package:gisila_orm/database/types.dart';
import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/migrations/schema_differ.dart';
import 'package:gisila_orm/query/expression.dart';
import 'package:gisila_orm/query/compiler.dart';
import 'package:test/test.dart';

void main() {
  group('Arrays', () {
    test('parses varchar[] / integer[] and emits SQL + Dart', () {
      const yaml = '''
Post:
  columns:
    tags:
      type: varchar[]
      is_null: false
      default: '{}'
    scores:
      type: integer[]
''';
      final schema = SchemaDefinition.fromYaml(yaml);
      final tags = schema.getModel('Post')!.columns.firstWhere((c) => c.name == 'tags');
      expect(tags.type, ColumnType.array);
      expect(tags.array!.elementType, ColumnType.varchar);
      expect(tags.postgresType, 'VARCHAR(255)[]');

      final up = emitUpSql(schema);
      expect(up, contains('"tags" VARCHAR(255)[] NOT NULL DEFAULT \'{}\'::varchar[]'));
      expect(up, contains('"scores" INTEGER[]'));

      final dart = emitDart(schema);
      expect(dart, contains('final List<String> tags;'));
      expect(dart, contains('final List<int>? scores;'));
      expect(dart, contains('ColumnRef<List<String>> tags'));
    });

    test('rejects unsupported array element types', () {
      expect(
        () => SchemaDefinition.fromYaml('''
Post:
  columns:
    embedding:
      type: vector[]
'''),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('array contains/overlaps compile via List bind', () {
      final col = ColumnRef<List<String>>(table: 'posts', column: 'tags');
      final compiled = SqlCompiler().compile(col.contains(['a', 'b']));
      expect(compiled, contains('@>'));
    });

    test('DefaultEngine formats YAML list array defaults', () {
      final formatted = DefaultEngine.instance.formatArrayDefault(
        ['a', 'b'],
        'varchar[]',
      );
      expect(formatted, contains('::varchar[]'));
      expect(formatted, contains('"a"'));
    });
  });

  group('Enums', () {
    test('CREATE TYPE + Dart enum + column typing', () {
      const yaml = '''
enums:
  TeamRole:
    - viewer
    - developer
    - admin

TeamMember:
  columns:
    role:
      type: TeamRole
      default: developer
      is_null: false
''';
      final schema = SchemaDefinition.fromYaml(yaml);
      expect(schema.enums.single.name, 'TeamRole');
      expect(schema.enums.single.values, ['viewer', 'developer', 'admin']);

      final role = schema.getModel('TeamMember')!.columns
          .firstWhere((c) => c.name == 'role');
      expect(role.type, ColumnType.enumType);
      expect(role.postgresType, '"team_role"');

      final up = emitUpSql(schema);
      expect(
        up,
        contains(
          "CREATE TYPE \"team_role\" AS ENUM ('viewer', 'developer', 'admin');",
        ),
      );
      expect(up, contains('"role" "team_role" NOT NULL DEFAULT \'developer\'::team_role'));

      final down = emitDownSql(schema);
      expect(down, contains('DROP TYPE IF EXISTS "team_role";'));

      final dart = emitDart(schema);
      expect(dart, contains('enum TeamRole {'));
      expect(dart, contains('final TeamRole role;'));
      expect(dart, contains('TeamRoleGisila.parse'));
    });

    test('rejects enum/model name collision', () {
      expect(
        () => SchemaDefinition.fromYaml('''
enums:
  User:
    - active

User:
  columns:
    email:
      type: varchar
'''),
        throwsA(isA<SchemaValidationException>()),
      );
    });

    test('differ adds new enum values', () {
      const oldYaml = '''
enums:
  Status:
    - created
Post:
  columns:
    status:
      type: Status
''';
      const newYaml = '''
enums:
  Status:
    - created
    - failed
Post:
  columns:
    status:
      type: Status
''';
      final diff = SchemaDiffer().compareSchemas(
        SchemaDefinition.fromYaml(oldYaml),
        SchemaDefinition.fromYaml(newYaml),
      );
      final sql = diff.operations.map((o) => o.upSql).join('\n');
      expect(sql, contains('ADD VALUE IF NOT EXISTS \'failed\''));
    });
  });

  group('CHECK constraints', () {
    test('column and model checks appear in SQL', () {
      const yaml = '''
Review:
  columns:
    rating:
      type: integer
      is_null: false
      check: "rating >= 1 AND rating <= 5"
    body:
      type: text
  checks:
    review_has_body:
      expression: "body IS NOT NULL"
''';
      final schema = SchemaDefinition.fromYaml(yaml);
      final up = emitUpSql(schema);
      expect(
        up,
        contains(
          'CONSTRAINT "reviews_rating_check" CHECK (rating >= 1 AND rating <= 5)',
        ),
      );
      expect(
        up,
        contains(
          'ADD CONSTRAINT "review_has_body" CHECK (body IS NOT NULL);',
        ),
      );
    });

    test('differ drops and re-adds changed checks', () {
      const oldYaml = '''
Item:
  columns:
    qty:
      type: integer
      check: "qty > 0"
''';
      const newYaml = '''
Item:
  columns:
    qty:
      type: integer
      check: "qty >= 0"
''';
      final diff = SchemaDiffer().compareSchemas(
        SchemaDefinition.fromYaml(oldYaml),
        SchemaDefinition.fromYaml(newYaml),
      );
      final sql = diff.operations.map((o) => o.upSql).join('\n');
      expect(sql, contains('DROP CONSTRAINT IF EXISTS "items_qty_check"'));
      expect(sql, contains('CHECK (qty >= 0)'));
    });
  });

  group('Geometrics', () {
    test('Point/Box/Circle/Lseg round-trip Postgres text', () {
      expect(Point.fromString('(1.5,2.5)'), Point(1.5, 2.5));
      expect(Point(1, 2).toSqlLiteral(), '(1.0,2.0)');

      final box = Box(Point(0, 0), Point(1, 1));
      expect(Box.fromString(box.toSqlLiteral()), box);

      final circle = Circle(Point(3, 4), 5);
      expect(Circle.fromString(circle.toSqlLiteral()), circle);

      final lseg = Lseg(Point(0, 0), Point(2, 3));
      expect(Lseg.fromString(lseg.toSqlLiteral()), lseg);
    });

    test('YAML point/box columns emit SQL and Dart coerce', () {
      const yaml = '''
Place:
  columns:
    location:
      type: point
      is_null: false
    bounds:
      type: box
''';
      final schema = SchemaDefinition.fromYaml(yaml);
      final up = emitUpSql(schema);
      expect(up, contains('"location" POINT NOT NULL'));
      expect(up, contains('"bounds" BOX'));

      final dart = emitDart(schema);
      expect(dart, contains('final Point location;'));
      expect(dart, contains('Point.fromString'));
      expect(dart, contains('location.toSqlLiteral()'));
    });

    test('compiler binds Point with ::point cast', () {
      final compiled = SqlCompiler().bind(Point(1, 2));
      expect(compiled, endsWith('::point'));
    });
  });
}
