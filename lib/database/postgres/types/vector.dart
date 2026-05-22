/// Dart side of PostgreSQL's `pgvector` extension.
///
/// The [Vector] class is a lightweight, immutable wrapper around a
/// fixed-length list of `double`s that knows how to round-trip
/// through Postgres' `vector` type. Use it both as a column field
/// (`Vector embedding;`) and as a query parameter (the `SqlCompiler`
/// special-cases it so it is sent as a text literal followed by a
/// `::vector` cast).
///
/// Construction is forgiving:
///
/// ```dart
/// final v1 = Vector([0.1, 0.2, 0.3]);
/// final v2 = Vector.fromList(<num>[1, 2, 3]);          // ints accepted
/// final v3 = Vector.parse('[0.1, 0.2, 0.3]');          // text from Postgres
/// ```
library gisila.database.postgres.types.vector;

import 'dart:math' as math;

/// Allowed pgvector distance operators / opclasses.
///
/// The enum names map onto the operator (`<->`, `<=>`, `<#>`) and the
/// opclass (`vector_l2_ops`, `vector_cosine_ops`, `vector_ip_ops`)
/// understood by both HNSW and IVFFlat indexes.
enum VectorDistance {
  /// Euclidean distance (`<->`, `vector_l2_ops`). The default.
  l2('<->', 'vector_l2_ops', 'l2'),

  /// Cosine distance (`<=>`, `vector_cosine_ops`).
  cosine('<=>', 'vector_cosine_ops', 'cosine'),

  /// Negative inner product (`<#>`, `vector_ip_ops`).
  innerProduct('<#>', 'vector_ip_ops', 'ip');

  const VectorDistance(this.op, this.opclass, this.alias);

  /// Postgres operator (`<->`, `<=>`, `<#>`).
  final String op;

  /// Postgres opclass used in `CREATE INDEX ... USING <method> (col <opclass>)`.
  final String opclass;

  /// Short alias accepted in the schema YAML (`l2`, `cosine`, `ip`).
  final String alias;

  /// Parse a YAML-friendly alias. Accepts both the enum [name] and the
  /// short [alias]; returns `null` if the value is not recognised.
  static VectorDistance? fromAlias(String value) {
    final v = value.toLowerCase();
    for (final d in VectorDistance.values) {
      if (d.alias == v || d.name.toLowerCase() == v) return d;
    }
    return null;
  }
}

/// Vector index method supported by pgvector (currently HNSW and
/// IVFFlat). The default at column level is [hnsw].
enum VectorIndexMethod {
  hnsw,
  ivfflat;

  static VectorIndexMethod? fromAlias(String value) {
    final v = value.toLowerCase();
    for (final m in VectorIndexMethod.values) {
      if (m.name == v) return m;
    }
    return null;
  }
}

/// An immutable dense vector of `double` values, matching the shape of
/// PostgreSQL `vector(n)` from the `pgvector` extension.
class Vector {
  /// Build a vector from a list of doubles. The list is copied
  /// defensively and made unmodifiable.
  Vector(List<double> values)
      : values = List<double>.unmodifiable(List<double>.from(values));

  /// Convenience constructor that accepts any numeric list (e.g. JSON
  /// data with mixed `int`/`double`).
  factory Vector.fromList(List<num> values) =>
      Vector([for (final v in values) v.toDouble()]);

  /// A zero vector of [dimensions]. Useful as a sentinel placeholder
  /// during tests and when building accumulator buffers.
  factory Vector.zeros(int dimensions) {
    if (dimensions < 0) {
      throw ArgumentError.value(
        dimensions,
        'dimensions',
        'must be non-negative',
      );
    }
    return Vector(List<double>.filled(dimensions, 0));
  }

  /// Parse pgvector's text format: `[0.1,0.2,0.3]`. Whitespace and
  /// trailing `::vector` casts are tolerated.
  factory Vector.parse(String text) {
    var s = text.trim();
    if (s.endsWith('::vector')) {
      s = s.substring(0, s.length - '::vector'.length).trim();
    }
    if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) {
      s = s.substring(1, s.length - 1).trim();
    }
    if (s.length < 2 || !s.startsWith('[') || !s.endsWith(']')) {
      throw FormatException(
        'Invalid pgvector text literal: "$text"; expected "[v1,v2,...]"',
      );
    }
    final inner = s.substring(1, s.length - 1).trim();
    if (inner.isEmpty) return Vector(const <double>[]);
    final parts = inner.split(',');
    final out = <double>[];
    for (final p in parts) {
      final t = p.trim();
      if (t.isEmpty) {
        throw FormatException('Empty value in vector literal "$text"');
      }
      out.add(double.parse(t));
    }
    return Vector(out);
  }

  /// Underlying values; immutable.
  final List<double> values;

  /// Number of dimensions in the vector.
  int get dimensions => values.length;

  /// Render in pgvector's text format (`[v1,v2,...]`) without a cast.
  /// Used by the [SqlCompiler] when binding as a parameter.
  String toSqlLiteral() => '[${values.join(',')}]';

  /// L2 (Euclidean) norm. Helper for tests / sanity checks.
  double get l2Norm {
    var s = 0.0;
    for (final v in values) {
      s += v * v;
    }
    return math.sqrt(s);
  }

  /// Dot product `this · other`. Throws [ArgumentError] when the two
  /// vectors have different dimensions.
  double dot(Vector other) {
    _checkSameDims(other, 'dot');
    var s = 0.0;
    for (var i = 0; i < values.length; i++) {
      s += values[i] * other.values[i];
    }
    return s;
  }

  /// L2-normalised copy of this vector. A zero vector is returned
  /// unchanged (avoiding division by zero) so the result is always
  /// safe to feed back into pgvector even at the edges.
  Vector get normalized {
    final n = l2Norm;
    if (n == 0) return this;
    return Vector([for (final v in values) v / n]);
  }

  /// Cosine similarity in `[-1.0, 1.0]`. Returns 0 when either vector
  /// is zero-magnitude. Throws [ArgumentError] when the two vectors
  /// have different dimensions.
  ///
  /// Note: pgvector's `<=>` operator returns *cosine distance*
  /// (`1 - similarity`); this helper returns similarity itself, which
  /// is what most ML pipelines expect.
  double cosineSimilarityTo(Vector other) {
    _checkSameDims(other, 'cosineSimilarityTo');
    final na = l2Norm;
    final nb = other.l2Norm;
    if (na == 0 || nb == 0) return 0;
    return dot(other) / (na * nb);
  }

  void _checkSameDims(Vector other, String op) {
    if (other.values.length != values.length) {
      throw ArgumentError(
        'Vector.$op: dimensions differ '
        '(${values.length} vs ${other.values.length})',
      );
    }
  }

  @override
  String toString() => 'Vector(${toSqlLiteral()})';

  @override
  bool operator ==(Object other) {
    if (other is! Vector) return false;
    if (other.values.length != values.length) return false;
    for (var i = 0; i < values.length; i++) {
      if (other.values[i] != values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);
}
