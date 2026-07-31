// GENERATED CODE - DO NOT MODIFY BY HAND
// Source: gisila build_runner schema generator.

// ignore_for_file: type=lint, unused_import

import 'package:gisila_orm/gisila.dart';

enum ReviewVerdict { pending, approved, rejected }

extension ReviewVerdictGisila on ReviewVerdict {
  /// Postgres ENUM label for this value.
  String get sqlValue => name;

  static ReviewVerdict parse(String raw) {
    for (final v in ReviewVerdict.values) {
      if (v.name == raw) return v;
    }
    throw FormatException('Unknown ReviewVerdict value: $raw');
  }
}

class Author with Preloadable {
  final int? id;
  final String firstName;
  final String? lastName;
  final String email;

  Author({
    this.id,
    required this.firstName,
    this.lastName,
    required this.email,
  });

  factory Author.fromRow(Map<String, dynamic> row) => Author(
    id: row['id'] as int?,
    firstName: row['first_name'] as String,
    lastName: row['last_name'] as String?,
    email: row['email'] as String,
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'first_name': firstName,
    'last_name': lastName,
    'email': email,
  };

  factory Author.fromJson(Map<String, dynamic> json) => Author.fromRow(json);

  Map<String, dynamic> toJson({
    List<String> exclude = const [],
    List<String> only = const [],
  }) {
    final row = toRow();
    if (only.isNotEmpty) return {for (final k in only) k: row[k]};
    if (exclude.isEmpty) return row;
    return Map.of(row)..removeWhere((k, _) => exclude.contains(k));
  }

  Author copyWith({
    int? id,
    String? firstName,
    String? lastName,
    String? email,
  }) => Author(
    id: id ?? this.id,
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    email: email ?? this.email,
  );

  /// Returns validation errors for this instance.
  ///
  /// Currently checks `allow_blank: false` string columns; empty
  /// when every such field is non-blank (or null).
  List<String> validate() {
    final errors = <String>[];
    if (email.trim().isEmpty) {
      errors.add('Author.email must not be blank');
    }
    return errors;
  }

  static final Relation<Author, Book> writtenBooks =
      HasManyRelation<Author, Book>(
        parentTable: 'authors',
        childTable: 'books',
        name: 'writtenBooks',
        childForeignKey: 'author_id',
        childMeta: BookTable.metadata,
      );

  /// Preloaded writtenBooks; empty list when not preloaded.
  List<Book> get writtenBooksList =>
      preloaded<List<Book>>('writtenBooks') ?? const [];
}

class AuthorTable {
  AuthorTable._();
  static const ColumnRef<int?> id = ColumnRef<int?>(
    table: 'authors',
    column: 'id',
  );
  static const ColumnRef<String> firstName = ColumnRef<String>(
    table: 'authors',
    column: 'first_name',
  );
  static const ColumnRef<String?> lastName = ColumnRef<String?>(
    table: 'authors',
    column: 'last_name',
  );
  static const ColumnRef<String> email = ColumnRef<String>(
    table: 'authors',
    column: 'email',
  );

  static const TableMeta<Author> metadata = TableMeta<Author>(
    tableName: 'authors',
    primaryKey: 'id',
    columnNames: ['id', 'first_name', 'last_name', 'email'],
    fromRow: Author.fromRow,
  );
}

Query<Author> authors() => Query<Author>(AuthorTable.metadata);

class Book with Preloadable {
  final int? id;
  final String title;
  final String? subtitle;
  final String? description;
  final DateTime? publishedDate;
  final String? isbn;
  final int? pageCount;
  final int? authorId;

  Book({
    this.id,
    required this.title,
    this.subtitle,
    this.description,
    this.publishedDate,
    this.isbn,
    this.pageCount,
    this.authorId,
  });

  factory Book.fromRow(Map<String, dynamic> row) => Book(
    id: row['id'] as int?,
    title: row['title'] as String,
    subtitle: row['subtitle'] as String?,
    description: row['description'] as String?,
    publishedDate: row['published_date'] == null
        ? null
        : (row['published_date'] is DateTime
              ? row['published_date'] as DateTime
              : DateTime.parse(row['published_date'].toString())),
    isbn: row['isbn'] as String?,
    pageCount: row['page_count'] as int?,
    authorId: row['author_id'] as int?,
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'description': description,
    'published_date': publishedDate,
    'isbn': isbn,
    'page_count': pageCount,
    'author_id': authorId,
  };

  factory Book.fromJson(Map<String, dynamic> json) => Book.fromRow(json);

  Map<String, dynamic> toJson({
    List<String> exclude = const [],
    List<String> only = const [],
  }) {
    final row = toRow();
    if (only.isNotEmpty) return {for (final k in only) k: row[k]};
    if (exclude.isEmpty) return row;
    return Map.of(row)..removeWhere((k, _) => exclude.contains(k));
  }

  Book copyWith({
    int? id,
    String? title,
    String? subtitle,
    String? description,
    DateTime? publishedDate,
    String? isbn,
    int? pageCount,
    int? authorId,
  }) => Book(
    id: id ?? this.id,
    title: title ?? this.title,
    subtitle: subtitle ?? this.subtitle,
    description: description ?? this.description,
    publishedDate: publishedDate ?? this.publishedDate,
    isbn: isbn ?? this.isbn,
    pageCount: pageCount ?? this.pageCount,
    authorId: authorId ?? this.authorId,
  );

  /// Returns validation errors for this instance.
  ///
  /// Currently checks `allow_blank: false` string columns; empty
  /// when every such field is non-blank (or null).
  List<String> validate() {
    final errors = <String>[];
    if (title.trim().isEmpty) {
      errors.add('Book.title must not be blank');
    }
    return errors;
  }

  static final Relation<Book, Author> author = BelongsToRelation<Book, Author>(
    parentTable: 'books',
    childTable: 'authors',
    name: 'author',
    parentForeignKey: 'author_id',
    childMeta: AuthorTable.metadata,
  );

  static final Relation<Book, User> reviewers = ManyToManyRelation<Book, User>(
    parentTable: 'books',
    childTable: 'users',
    name: 'reviewers',
    junctionTable: 'books_users',
    junctionParentKey: 'book_id',
    junctionChildKey: 'user_id',
    childMeta: UserTable.metadata,
  );

  static final Relation<Book, Review> reviews = HasManyRelation<Book, Review>(
    parentTable: 'books',
    childTable: 'reviews',
    name: 'reviews',
    childForeignKey: 'book_id',
    childMeta: ReviewTable.metadata,
  );

  /// Preloaded author; null when not preloaded or absent.
  Author? get authorLoaded => preloaded<Author>('author');

  /// Preloaded reviewers; empty list when not preloaded.
  List<User> get reviewersList =>
      preloaded<List<User>>('reviewers') ?? const [];

  /// Preloaded reviews; empty list when not preloaded.
  List<Review> get reviewsList =>
      preloaded<List<Review>>('reviews') ?? const [];
}

class BookTable {
  BookTable._();
  static const ColumnRef<int?> id = ColumnRef<int?>(
    table: 'books',
    column: 'id',
  );
  static const ColumnRef<String> title = ColumnRef<String>(
    table: 'books',
    column: 'title',
  );
  static const ColumnRef<String?> subtitle = ColumnRef<String?>(
    table: 'books',
    column: 'subtitle',
  );
  static const ColumnRef<String?> description = ColumnRef<String?>(
    table: 'books',
    column: 'description',
  );
  static const ColumnRef<DateTime?> publishedDate = ColumnRef<DateTime?>(
    table: 'books',
    column: 'published_date',
  );
  static const ColumnRef<String?> isbn = ColumnRef<String?>(
    table: 'books',
    column: 'isbn',
  );
  static const ColumnRef<int?> pageCount = ColumnRef<int?>(
    table: 'books',
    column: 'page_count',
  );
  static const ColumnRef<int?> authorId = ColumnRef<int?>(
    table: 'books',
    column: 'author_id',
  );

  static const TableMeta<Book> metadata = TableMeta<Book>(
    tableName: 'books',
    primaryKey: 'id',
    columnNames: [
      'id',
      'title',
      'subtitle',
      'description',
      'published_date',
      'isbn',
      'page_count',
      'author_id',
    ],
    fromRow: Book.fromRow,
  );
}

Query<Book> books() => Query<Book>(BookTable.metadata);

class Place with Preloadable {
  final int? id;
  final String name;
  final Point location;
  final Box? bounds;

  Place({this.id, required this.name, required this.location, this.bounds});

  factory Place.fromRow(Map<String, dynamic> row) => Place(
    id: row['id'] as int?,
    name: row['name'] as String,
    location: row['location'] is Point
        ? row['location'] as Point
        : Point.fromString(row['location'].toString()),
    bounds: row['bounds'] == null
        ? null
        : (row['bounds'] is Box
              ? row['bounds'] as Box
              : Box.fromString(row['bounds'].toString())),
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'name': name,
    'location': location.toSqlLiteral(),
    'bounds': bounds?.toSqlLiteral(),
  };

  factory Place.fromJson(Map<String, dynamic> json) => Place.fromRow(json);

  Map<String, dynamic> toJson({
    List<String> exclude = const [],
    List<String> only = const [],
  }) {
    final row = toRow();
    if (only.isNotEmpty) return {for (final k in only) k: row[k]};
    if (exclude.isEmpty) return row;
    return Map.of(row)..removeWhere((k, _) => exclude.contains(k));
  }

  Place copyWith({int? id, String? name, Point? location, Box? bounds}) =>
      Place(
        id: id ?? this.id,
        name: name ?? this.name,
        location: location ?? this.location,
        bounds: bounds ?? this.bounds,
      );

  /// Returns validation errors for this instance.
  ///
  /// Currently checks `allow_blank: false` string columns; empty
  /// when every such field is non-blank (or null).
  List<String> validate() {
    final errors = <String>[];
    return errors;
  }
}

class PlaceTable {
  PlaceTable._();
  static const ColumnRef<int?> id = ColumnRef<int?>(
    table: 'places',
    column: 'id',
  );
  static const ColumnRef<String> name = ColumnRef<String>(
    table: 'places',
    column: 'name',
  );
  static const ColumnRef<Point> location = ColumnRef<Point>(
    table: 'places',
    column: 'location',
  );
  static const ColumnRef<Box?> bounds = ColumnRef<Box?>(
    table: 'places',
    column: 'bounds',
  );

  static const TableMeta<Place> metadata = TableMeta<Place>(
    tableName: 'places',
    primaryKey: 'id',
    columnNames: ['id', 'name', 'location', 'bounds'],
    fromRow: Place.fromRow,
  );
}

Query<Place> places() => Query<Place>(PlaceTable.metadata);

class Review with Preloadable {
  final int? id;
  final int? bookId;
  final int? reviewerId;
  final int? rating;
  final ReviewVerdict verdict;
  final List<String>? tags;
  final String? reviewText;
  final DateTime reviewDate;
  final bool isApproved;
  final bool isFlagged;
  final bool isDeleted;
  final bool isSpam;
  final bool isInappropriate;
  final bool isHarmful;

  Review({
    this.id,
    this.bookId,
    this.reviewerId,
    this.rating,
    required this.verdict,
    this.tags,
    this.reviewText,
    required this.reviewDate,
    required this.isApproved,
    required this.isFlagged,
    required this.isDeleted,
    required this.isSpam,
    required this.isInappropriate,
    required this.isHarmful,
  });

  factory Review.fromRow(Map<String, dynamic> row) => Review(
    id: row['id'] as int?,
    bookId: row['book_id'] as int?,
    reviewerId: row['reviewer_id'] as int?,
    rating: row['rating'] as int?,
    verdict: ReviewVerdictGisila.parse(row['verdict'].toString()),
    tags: row['tags'] == null
        ? null
        : (row['tags'] is List
              ? (row['tags'] as List)
                    .map((e) => e.toString())
                    .toList()
                    .cast<String>()
              : <String>[]),
    reviewText: row['review_text'] as String?,
    reviewDate: row['review_date'] is DateTime
        ? row['review_date'] as DateTime
        : DateTime.parse(row['review_date'].toString()),
    isApproved: row['is_approved'] as bool,
    isFlagged: row['is_flagged'] as bool,
    isDeleted: row['is_deleted'] as bool,
    isSpam: row['is_spam'] as bool,
    isInappropriate: row['is_inappropriate'] as bool,
    isHarmful: row['is_harmful'] as bool,
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'book_id': bookId,
    'reviewer_id': reviewerId,
    'rating': rating,
    'verdict': verdict.sqlValue,
    'tags': tags,
    'review_text': reviewText,
    'review_date': reviewDate,
    'is_approved': isApproved,
    'is_flagged': isFlagged,
    'is_deleted': isDeleted,
    'is_spam': isSpam,
    'is_inappropriate': isInappropriate,
    'is_harmful': isHarmful,
  };

  factory Review.fromJson(Map<String, dynamic> json) => Review.fromRow(json);

  Map<String, dynamic> toJson({
    List<String> exclude = const [],
    List<String> only = const [],
  }) {
    final row = toRow();
    if (only.isNotEmpty) return {for (final k in only) k: row[k]};
    if (exclude.isEmpty) return row;
    return Map.of(row)..removeWhere((k, _) => exclude.contains(k));
  }

  Review copyWith({
    int? id,
    int? bookId,
    int? reviewerId,
    int? rating,
    ReviewVerdict? verdict,
    List<String>? tags,
    String? reviewText,
    DateTime? reviewDate,
    bool? isApproved,
    bool? isFlagged,
    bool? isDeleted,
    bool? isSpam,
    bool? isInappropriate,
    bool? isHarmful,
  }) => Review(
    id: id ?? this.id,
    bookId: bookId ?? this.bookId,
    reviewerId: reviewerId ?? this.reviewerId,
    rating: rating ?? this.rating,
    verdict: verdict ?? this.verdict,
    tags: tags ?? this.tags,
    reviewText: reviewText ?? this.reviewText,
    reviewDate: reviewDate ?? this.reviewDate,
    isApproved: isApproved ?? this.isApproved,
    isFlagged: isFlagged ?? this.isFlagged,
    isDeleted: isDeleted ?? this.isDeleted,
    isSpam: isSpam ?? this.isSpam,
    isInappropriate: isInappropriate ?? this.isInappropriate,
    isHarmful: isHarmful ?? this.isHarmful,
  );

  /// Returns validation errors for this instance.
  ///
  /// Currently checks `allow_blank: false` string columns; empty
  /// when every such field is non-blank (or null).
  List<String> validate() {
    final errors = <String>[];
    return errors;
  }

  static final Relation<Review, Book> book = BelongsToRelation<Review, Book>(
    parentTable: 'reviews',
    childTable: 'books',
    name: 'book',
    parentForeignKey: 'book_id',
    childMeta: BookTable.metadata,
  );

  static final Relation<Review, User> reviewer =
      BelongsToRelation<Review, User>(
        parentTable: 'reviews',
        childTable: 'users',
        name: 'reviewer',
        parentForeignKey: 'reviewer_id',
        childMeta: UserTable.metadata,
      );

  /// Preloaded book; null when not preloaded or absent.
  Book? get bookLoaded => preloaded<Book>('book');

  /// Preloaded reviewer; null when not preloaded or absent.
  User? get reviewerLoaded => preloaded<User>('reviewer');
}

class ReviewTable {
  ReviewTable._();
  static const ColumnRef<int?> id = ColumnRef<int?>(
    table: 'reviews',
    column: 'id',
  );
  static const ColumnRef<int?> bookId = ColumnRef<int?>(
    table: 'reviews',
    column: 'book_id',
  );
  static const ColumnRef<int?> reviewerId = ColumnRef<int?>(
    table: 'reviews',
    column: 'reviewer_id',
  );
  static const ColumnRef<int?> rating = ColumnRef<int?>(
    table: 'reviews',
    column: 'rating',
  );
  static const ColumnRef<ReviewVerdict> verdict = ColumnRef<ReviewVerdict>(
    table: 'reviews',
    column: 'verdict',
  );
  static const ColumnRef<List<String>?> tags = ColumnRef<List<String>?>(
    table: 'reviews',
    column: 'tags',
  );
  static const ColumnRef<String?> reviewText = ColumnRef<String?>(
    table: 'reviews',
    column: 'review_text',
  );
  static const ColumnRef<DateTime> reviewDate = ColumnRef<DateTime>(
    table: 'reviews',
    column: 'review_date',
  );
  static const ColumnRef<bool> isApproved = ColumnRef<bool>(
    table: 'reviews',
    column: 'is_approved',
  );
  static const ColumnRef<bool> isFlagged = ColumnRef<bool>(
    table: 'reviews',
    column: 'is_flagged',
  );
  static const ColumnRef<bool> isDeleted = ColumnRef<bool>(
    table: 'reviews',
    column: 'is_deleted',
  );
  static const ColumnRef<bool> isSpam = ColumnRef<bool>(
    table: 'reviews',
    column: 'is_spam',
  );
  static const ColumnRef<bool> isInappropriate = ColumnRef<bool>(
    table: 'reviews',
    column: 'is_inappropriate',
  );
  static const ColumnRef<bool> isHarmful = ColumnRef<bool>(
    table: 'reviews',
    column: 'is_harmful',
  );

  static const TableMeta<Review> metadata = TableMeta<Review>(
    tableName: 'reviews',
    primaryKey: 'id',
    columnNames: [
      'id',
      'book_id',
      'reviewer_id',
      'rating',
      'verdict',
      'tags',
      'review_text',
      'review_date',
      'is_approved',
      'is_flagged',
      'is_deleted',
      'is_spam',
      'is_inappropriate',
      'is_harmful',
    ],
    fromRow: Review.fromRow,
  );
}

Query<Review> reviews() => Query<Review>(ReviewTable.metadata);

class User with Preloadable {
  final int? id;
  final String firstName;
  final String? lastName;
  final String email;
  final String password;
  final DateTime dateJoined;

  User({
    this.id,
    required this.firstName,
    this.lastName,
    required this.email,
    required this.password,
    required this.dateJoined,
  });

  factory User.fromRow(Map<String, dynamic> row) => User(
    id: row['id'] as int?,
    firstName: row['first_name'] as String,
    lastName: row['last_name'] as String?,
    email: row['email'] as String,
    password: row['password'] as String,
    dateJoined: row['date_joined'] is DateTime
        ? row['date_joined'] as DateTime
        : DateTime.parse(row['date_joined'].toString()),
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'first_name': firstName,
    'last_name': lastName,
    'email': email,
    'password': password,
    'date_joined': dateJoined,
  };

  factory User.fromJson(Map<String, dynamic> json) => User.fromRow(json);

  Map<String, dynamic> toJson({
    List<String> exclude = const [],
    List<String> only = const [],
  }) {
    final row = toRow();
    if (only.isNotEmpty) return {for (final k in only) k: row[k]};
    if (exclude.isEmpty) return row;
    return Map.of(row)..removeWhere((k, _) => exclude.contains(k));
  }

  User copyWith({
    int? id,
    String? firstName,
    String? lastName,
    String? email,
    String? password,
    DateTime? dateJoined,
  }) => User(
    id: id ?? this.id,
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    email: email ?? this.email,
    password: password ?? this.password,
    dateJoined: dateJoined ?? this.dateJoined,
  );

  /// Returns validation errors for this instance.
  ///
  /// Currently checks `allow_blank: false` string columns; empty
  /// when every such field is non-blank (or null).
  List<String> validate() {
    final errors = <String>[];
    if (email.trim().isEmpty) {
      errors.add('User.email must not be blank');
    }
    if (password.trim().isEmpty) {
      errors.add('User.password must not be blank');
    }
    return errors;
  }

  static final Relation<User, Book> reviewedBooks =
      ManyToManyRelation<User, Book>(
        parentTable: 'users',
        childTable: 'books',
        name: 'reviewedBooks',
        junctionTable: 'books_users',
        junctionParentKey: 'user_id',
        junctionChildKey: 'book_id',
        childMeta: BookTable.metadata,
      );

  static final Relation<User, Review> reviews = HasManyRelation<User, Review>(
    parentTable: 'users',
    childTable: 'reviews',
    name: 'reviews',
    childForeignKey: 'reviewer_id',
    childMeta: ReviewTable.metadata,
  );

  /// Preloaded reviewedBooks; empty list when not preloaded.
  List<Book> get reviewedBooksList =>
      preloaded<List<Book>>('reviewedBooks') ?? const [];

  /// Preloaded reviews; empty list when not preloaded.
  List<Review> get reviewsList =>
      preloaded<List<Review>>('reviews') ?? const [];
}

class UserTable {
  UserTable._();
  static const ColumnRef<int?> id = ColumnRef<int?>(
    table: 'users',
    column: 'id',
  );
  static const ColumnRef<String> firstName = ColumnRef<String>(
    table: 'users',
    column: 'first_name',
  );
  static const ColumnRef<String?> lastName = ColumnRef<String?>(
    table: 'users',
    column: 'last_name',
  );
  static const ColumnRef<String> email = ColumnRef<String>(
    table: 'users',
    column: 'email',
  );
  static const ColumnRef<String> password = ColumnRef<String>(
    table: 'users',
    column: 'password',
  );
  static const ColumnRef<DateTime> dateJoined = ColumnRef<DateTime>(
    table: 'users',
    column: 'date_joined',
  );

  static const TableMeta<User> metadata = TableMeta<User>(
    tableName: 'users',
    primaryKey: 'id',
    columnNames: [
      'id',
      'first_name',
      'last_name',
      'email',
      'password',
      'date_joined',
    ],
    fromRow: User.fromRow,
  );
}

Query<User> users() => Query<User>(UserTable.metadata);
