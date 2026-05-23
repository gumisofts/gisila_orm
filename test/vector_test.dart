/// Coverage for the pgvector integration: the `Vector` value type, the
/// query-builder distance operators, the YAML schema parser, the
/// SQL/Dart code emitters, and incremental migrations via the schema
/// differ.
///
/// These tests run entirely in-process - no PostgreSQL required.
library gisila.test.vector_test;

import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/gisila.dart';
import 'package:test/test.dart';

void main() {
  group('Vector value type', () {
    test('round-trips through toSqlLiteral / parse', () {
      final v = Vector([0.1, -2.5, 3]);
      expect(v.toSqlLiteral(), '[0.1,-2.5,3.0]');
      expect(Vector.parse(v.toSqlLiteral()), v);
    });

    test('parse tolerates whitespace, quotes, and `::vector` cast', () {
      expect(
        Vector.parse(" '[1.0, 2.0, 3.0]'::vector "),
        Vector([1, 2, 3]),
      );
    });

    test('rejects malformed text', () {
      expect(() => Vector.parse('1,2,3'), throwsFormatException);
      expect(() => Vector.parse('[1,,2]'), throwsFormatException);
    });

    test('equality is value-based', () {
      expect(Vector([1, 2, 3]), Vector([1, 2, 3]));
      expect(Vector([1, 2, 3]).hashCode, Vector([1, 2, 3]).hashCode);
      expect(Vector([1, 2, 3]), isNot(Vector([1, 2])));
    });

    test('fromList accepts mixed int/double', () {
      final v = Vector.fromList(<num>[1, 2.5, 3]);
      expect(v.values, [1.0, 2.5, 3.0]);
    });

    test('VectorDistance.fromAlias maps short names', () {
      expect(VectorDistance.fromAlias('l2'), VectorDistance.l2);
      expect(VectorDistance.fromAlias('cosine'), VectorDistance.cosine);
      expect(VectorDistance.fromAlias('ip'), VectorDistance.innerProduct);
      expect(VectorDistance.fromAlias('hamming'), isNull);
    });
  });

  group('Query compiler: vector distance ops', () {
    const embedding =
        ColumnRef<Vector>(table: 'documents', column: 'embedding');
    final query = Vector([0.1, 0.2, 0.3]);

    test('cosineDistance compiles to <=> with a ::vector cast', () {
      final c = Query<Map<String, dynamic>>(TableMeta<Map<String, dynamic>>(
        tableName: 'documents',
        columnNames: const ['id', 'embedding'],
        fromRow: (r) => r,
      )).orderBy(embedding.cosineDistance(query)).limit(5).compile();

      expect(
        c.sql,
        contains('"documents"."embedding" <=> \$1::vector'),
      );
      expect(c.sql, endsWith('LIMIT 5'));
      expect(c.params, [query.toSqlLiteral()]);
    });

    test('l2Distance and innerProduct map to the correct operators', () {
      final l2 = SqlCompiler();
      final ip = SqlCompiler();
      expect(
        embedding.l2Distance(query).accept(l2),
        '("documents"."embedding" <-> \$1::vector)',
      );
      expect(
        embedding.innerProduct(query).accept(ip),
        '("documents"."embedding" <#> \$1::vector)',
      );
    });

    test('VectorLiteral binds the text form and emits a cast', () {
      final c = SqlCompiler();
      final sql = VectorLiteral(Vector([1, 2, 3])).accept(c);
      expect(sql, '\$1::vector');
      expect(c.params, ['[1.0,2.0,3.0]']);
    });

    test('InsertQuery binds a Vector field via ::vector cast', () {
      final c = Query<Map<String, dynamic>>(TableMeta<Map<String, dynamic>>(
        tableName: 'documents',
        columnNames: const ['embedding'],
        fromRow: (r) => r,
      )).insert({
        'embedding': Vector([0, 0.5, 1])
      }).compile();

      expect(
        c.sql,
        'INSERT INTO "documents" ("embedding") VALUES (\$1::vector) '
        'RETURNING *',
      );
      expect(c.params, ['[0.0,0.5,1.0]']);
    });
  });

  group('Schema parser: vector columns', () {
    test('happy path parses dimensions, index_method, and distance', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      is_null: false
    embedding:
      type: vector
      dimensions: 1536
      is_null: false
      is_index: true
      index_method: hnsw
      distance: cosine
''');

      final doc = schema.getModel('Document')!;
      final emb = doc.columns.firstWhere((c) => c.name == 'embedding');
      expect(emb.type, ColumnType.vector);
      expect(emb.dartType, 'Vector');
      expect(emb.postgresType, 'VECTOR(1536)');
      expect(emb.vector?.dimensions, 1536);
      expect(emb.vector?.indexMethod, VectorIndexMethod.hnsw);
      expect(emb.vector?.distance, VectorDistance.cosine);
    });

    test('missing dimensions surfaces a structured error', () {
      expect(
        () => SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      is_null: false
'''),
        throwsA(isA<SchemaValidationException>().having(
          (e) => e.errors.first.code,
          'first error code',
          'missing_dimensions',
        )),
      );
    });

    test('vector-only keys on a non-vector column are rejected', () {
      expect(
        () => SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      dimensions: 1536
'''),
        throwsA(isA<SchemaValidationException>().having(
          (e) => e.errors.first.code,
          'first error code',
          'invalid_vector_option',
        )),
      );
    });

    test('explicit vector index block parses `using` and `distance`', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
  indexes:
    embedding_ivf:
      columns: [embedding]
      using: ivfflat
      distance: cosine
''');
      final idx = schema.getModel('Document')!.indexes.single;
      expect(idx.using, VectorIndexMethod.ivfflat);
      expect(idx.distance, VectorDistance.cosine);
    });
  });

  group('SQL emitter: vector tables and indexes', () {
    test('emits CREATE EXTENSION + VECTOR(n) + HNSW index DDL', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 3
      is_null: false
      is_index: true
      index_method: hnsw
      distance: l2
''');

      final up = emitUpSql(schema);
      expect(up, contains('CREATE EXTENSION IF NOT EXISTS vector;'));
      expect(up, contains('"embedding" VECTOR(3) NOT NULL'));
      expect(
        up,
        contains(
          'CREATE INDEX "idx_documents_embedding" ON "documents" '
          'USING hnsw ("embedding" vector_l2_ops);',
        ),
      );
    });

    test('explicit `using: ivfflat` block emits the correct opclass', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
  indexes:
    embedding_ivf:
      columns: [embedding]
      using: ivfflat
      distance: cosine
''');

      final up = emitUpSql(schema);
      expect(
        up,
        contains(
          'CREATE INDEX "embedding_ivf" ON "documents" '
          'USING ivfflat ("embedding" vector_cosine_ops);',
        ),
      );
    });

    test('no CREATE EXTENSION line for vector-free schemas', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      is_null: false
''');
      expect(emitUpSql(schema), isNot(contains('vector')));
    });
  });

  group('Dart emitter: vector field generation', () {
    test('generated model exposes Vector field + ColumnRef<Vector>', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 4
      is_null: false
''');

      final out = emitDart(schema);
      expect(out, contains('final Vector embedding;'));
      expect(out, contains('static const ColumnRef<Vector> embedding'));
      // The hydrator must accept either a Vector, a List<num>, or text.
      expect(out, contains('Vector.parse('));
      expect(out, contains('Vector.fromList('));
    });

    test('nullable vector column hydrates as Vector? with a null guard', () {
      final schema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 4
''');
      final out = emitDart(schema);
      expect(out, contains('final Vector? embedding;'));
      expect(out, contains("row['embedding'] == null ? null"));
    });
  });

  group('Vector math helpers', () {
    test('Vector.zeros creates the right-sized zero vector', () {
      expect(Vector.zeros(3).values, [0.0, 0.0, 0.0]);
      expect(Vector.zeros(0).dimensions, 0);
      expect(() => Vector.zeros(-1), throwsArgumentError);
    });

    test('dot product computes a + b + c correctly', () {
      final a = Vector([1, 2, 3]);
      final b = Vector([4, -5, 6]);
      // 1*4 + 2*-5 + 3*6 = 4 - 10 + 18 = 12
      expect(a.dot(b), 12.0);
    });

    test('dot product rejects mismatched dimensions', () {
      expect(() => Vector([1, 2]).dot(Vector([1, 2, 3])), throwsArgumentError);
    });

    test('normalized returns a unit vector and preserves direction', () {
      final v = Vector([3, 4]).normalized;
      expect(v.values[0], closeTo(0.6, 1e-9));
      expect(v.values[1], closeTo(0.8, 1e-9));
      expect(v.l2Norm, closeTo(1.0, 1e-9));
    });

    test('normalized leaves a zero vector unchanged', () {
      final z = Vector.zeros(4);
      expect(z.normalized, z);
    });

    test('cosineSimilarityTo returns 1.0 for parallel vectors', () {
      final a = Vector([1, 2, 3]);
      final b = Vector([2, 4, 6]); // 2 * a
      expect(a.cosineSimilarityTo(b), closeTo(1.0, 1e-9));
    });

    test('cosineSimilarityTo returns 0.0 for orthogonal vectors', () {
      expect(Vector([1, 0]).cosineSimilarityTo(Vector([0, 1])), 0.0);
    });

    test('cosineSimilarityTo guards against zero vectors', () {
      expect(Vector.zeros(3).cosineSimilarityTo(Vector([1, 2, 3])), 0.0);
    });
  });

  group('SchemaDiffer: incremental vector migrations', () {
    test(
        'adding the first vector column prepends CREATE EXTENSION '
        'and emits the implicit HNSW index', () {
      final oldSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      is_null: false
''');
      final newSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      is_null: false
    embedding:
      type: vector
      dimensions: 1536
      is_null: false
      is_index: true
      index_method: hnsw
      distance: cosine
''');

      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);
      final ups = diff.operations.map((o) => o.upSql).toList();

      expect(ups.first, 'CREATE EXTENSION IF NOT EXISTS vector;');
      final addCol = ups.firstWhere((s) => s.contains('ADD COLUMN'));
      expect(addCol, contains('"embedding" VECTOR(1536) NOT NULL'));
      expect(
        addCol,
        contains(
          'CREATE INDEX "idx_documents_embedding" ON "documents" '
          'USING hnsw ("embedding" vector_cosine_ops);',
        ),
      );

      // Rollback should drop the index and the column, but leave the
      // extension installed for safety.
      final downs = diff.operations.map((o) => o.downSql).toList();
      final addColDown = downs.firstWhere((s) => s.contains('DROP COLUMN'));
      expect(addColDown,
          contains('DROP INDEX IF EXISTS "idx_documents_embedding"'));
      expect(downs.first, contains('pgvector extension intentionally left'));
    });

    test(
        'no CREATE EXTENSION when the old schema already had a vector '
        'column', () {
      final oldSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
''');
      final newSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
    embedding_v2:
      type: vector
      dimensions: 16
      is_null: false
''');

      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);
      expect(
        diff.operations.any((o) => o.upSql.contains('CREATE EXTENSION')),
        isFalse,
      );
    });

    test('switching distance metric drops and re-creates the index', () {
      final oldSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
      is_index: true
      index_method: hnsw
      distance: l2
''');
      final newSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
      is_index: true
      index_method: hnsw
      distance: cosine
''');

      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);
      final modify = diff.operations
          .firstWhere((o) => o.change.type == ChangeType.modifyColumn);
      expect(modify.upSql,
          contains('DROP INDEX IF EXISTS "idx_documents_embedding"'));
      expect(
        modify.upSql,
        contains(
          'CREATE INDEX "idx_documents_embedding" ON "documents" '
          'USING hnsw ("embedding" vector_cosine_ops);',
        ),
      );
    });

    test('flipping is_index: true -> false drops the implicit index', () {
      final oldSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
      is_index: true
''');
      final newSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    embedding:
      type: vector
      dimensions: 8
      is_null: false
''');

      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);
      final modify = diff.operations
          .firstWhere((o) => o.change.type == ChangeType.modifyColumn);
      expect(modify.upSql,
          contains('DROP INDEX IF EXISTS "idx_documents_embedding"'));
      expect(modify.upSql, isNot(contains('CREATE INDEX')));
    });

    test('dropping a vector column drops its implicit index first', () {
      final oldSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      is_null: false
    embedding:
      type: vector
      dimensions: 8
      is_null: false
      is_index: true
''');
      final newSchema = SchemaDefinition.fromYaml('''
Document:
  columns:
    title:
      type: varchar
      is_null: false
''');

      final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);
      final drop = diff.operations
          .firstWhere((o) => o.change.type == ChangeType.dropColumn);
      final upLines = drop.upSql.split('\n');
      expect(upLines.first, contains('DROP INDEX'));
      expect(upLines.last, contains('DROP COLUMN "embedding"'));
    });
  });
}
