/// PostgreSQL geometric value types for Gisila ORM.
///
/// Text class round-trips the canonical Postgres text representation used
/// by the `point` / `box` / `circle` / `lseg` types. The obsolete list-of-
/// points `Line` helper was removed — Postgres `line` uses `{A,B,C}` and
/// is not supported in schema YAML yet.
library gisila.database.postgres.types.geometrics;

/// Postgres `point` — `(x,y)`.
class Point {
  final double x;
  final double y;

  const Point(this.x, this.y);

  String toSqlLiteral() => '($x,$y)';

  @override
  String toString() => toSqlLiteral();

  static Point fromString(String value) {
    final match = RegExp(r'^\(\s*([^,]+)\s*,\s*([^)]+)\s*\)$').firstMatch(
      value.trim(),
    );
    if (match == null) {
      throw FormatException('Invalid Point format: $value');
    }
    return Point(
      double.parse(match.group(1)!.trim()),
      double.parse(match.group(2)!.trim()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// Postgres `box` — `((x1,y1),(x2,y2))`.
class Box {
  final Point corner1;
  final Point corner2;

  const Box(this.corner1, this.corner2);

  String toSqlLiteral() =>
      '(${corner1.toSqlLiteral()},${corner2.toSqlLiteral()})';

  @override
  String toString() => toSqlLiteral();

  static Box fromString(String value) {
    final match = RegExp(
      r'^\(\s*(\([^)]+\))\s*,\s*(\([^)]+\))\s*\)$',
    ).firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid Box format: $value');
    }
    return Box(
      Point.fromString(match.group(1)!.trim()),
      Point.fromString(match.group(2)!.trim()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Box && other.corner1 == corner1 && other.corner2 == corner2;

  @override
  int get hashCode => Object.hash(corner1, corner2);
}

/// Postgres `circle` — `<(x,y),r>`.
class Circle {
  final Point center;
  final double radius;

  const Circle(this.center, this.radius);

  String toSqlLiteral() => '<${center.toSqlLiteral()},$radius>';

  @override
  String toString() => toSqlLiteral();

  static Circle fromString(String value) {
    final match = RegExp(
      r'^<\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)\s*,\s*([^>]+)\s*>$',
    ).firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid Circle format: $value');
    }
    return Circle(
      Point(
        double.parse(match.group(1)!.trim()),
        double.parse(match.group(2)!.trim()),
      ),
      double.parse(match.group(3)!.trim()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Circle && other.center == center && other.radius == radius;

  @override
  int get hashCode => Object.hash(center, radius);
}

/// Postgres `lseg` — `[(x1,y1),(x2,y2)]`.
class Lseg {
  final Point start;
  final Point end;

  const Lseg(this.start, this.end);

  String toSqlLiteral() => '[${start.toSqlLiteral()},${end.toSqlLiteral()}]';

  @override
  String toString() => toSqlLiteral();

  static Lseg fromString(String value) {
    final match = RegExp(
      r'^\[\s*(\([^)]+\))\s*,\s*(\([^)]+\))\s*\]$',
    ).firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid Lseg format: $value');
    }
    return Lseg(
      Point.fromString(match.group(1)!.trim()),
      Point.fromString(match.group(2)!.trim()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Lseg && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}
