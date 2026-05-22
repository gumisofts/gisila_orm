// GENERATED CODE - DO NOT MODIFY BY HAND
// Source: gisila build_runner schema generator.

// ignore_for_file: type=lint, unused_import

import 'package:gisila_orm/gisila.dart';

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

  Map<String, dynamic> toJson() => toRow();

  User copyWith({
    int? id,
    String? firstName,
    String? lastName,
    String? email,
    String? password,
    DateTime? dateJoined,
  }) =>
      User(
        id: id ?? this.id,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        email: email ?? this.email,
        password: password ?? this.password,
        dateJoined: dateJoined ?? this.dateJoined,
      );

  static final Relation<User, Book> reviewedBooks =
      ManyToManyRelation<User, Book>(
    parentTable: 'user',
    childTable: 'book',
    name: 'reviewedBooks',
    junctionTable: 'book_user',
    junctionParentKey: 'user_id',
    junctionChildKey: 'book_id',
    childMeta: BookTable.metadata,
  );

  static final Relation<User, Review> reviews = HasManyRelation<User, Review>(
    parentTable: 'user',
    childTable: 'review',
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
    table: 'user',
    column: 'id',
  );
  static const ColumnRef<String> firstName = ColumnRef<String>(
    table: 'user',
    column: 'first_name',
  );
  static const ColumnRef<String?> lastName = ColumnRef<String?>(
    table: 'user',
    column: 'last_name',
  );
  static const ColumnRef<String> email = ColumnRef<String>(
    table: 'user',
    column: 'email',
  );
  static const ColumnRef<String> password = ColumnRef<String>(
    table: 'user',
    column: 'password',
  );
  static const ColumnRef<DateTime> dateJoined = ColumnRef<DateTime>(
    table: 'user',
    column: 'date_joined',
  );

  static const TableMeta<User> metadata = TableMeta<User>(
    tableName: 'user',
    primaryKey: 'id',
    columnNames: [
      'id',
      'first_name',
      'last_name',
      'email',
      'password',
      'date_joined'
    ],
    fromRow: User.fromRow,
  );
}

Query<User> users() => Query<User>(UserTable.metadata);

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

  Map<String, dynamic> toJson() => toRow();

  Author copyWith({
    int? id,
    String? firstName,
    String? lastName,
    String? email,
  }) =>
      Author(
        id: id ?? this.id,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        email: email ?? this.email,
      );

  static final Relation<Author, Book> writtenBooks =
      HasManyRelation<Author, Book>(
    parentTable: 'author',
    childTable: 'book',
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
    table: 'author',
    column: 'id',
  );
  static const ColumnRef<String> firstName = ColumnRef<String>(
    table: 'author',
    column: 'first_name',
  );
  static const ColumnRef<String?> lastName = ColumnRef<String?>(
    table: 'author',
    column: 'last_name',
  );
  static const ColumnRef<String> email = ColumnRef<String>(
    table: 'author',
    column: 'email',
  );

  static const TableMeta<Author> metadata = TableMeta<Author>(
    tableName: 'author',
    primaryKey: 'id',
    columnNames: ['id', 'first_name', 'last_name', 'email'],
    fromRow: Author.fromRow,
  );
}

Query<Author> authors() => Query<Author>(AuthorTable.metadata);

class Book with Preloadable {
  final String? title;
  final String? subtitle;
  final String? description;
  final DateTime? publishedDate;
  final String? isbn;
  final int? pageCount;
  final int? authorId;

  Book({
    this.title,
    this.subtitle,
    this.description,
    this.publishedDate,
    this.isbn,
    this.pageCount,
    this.authorId,
  });

  factory Book.fromRow(Map<String, dynamic> row) => Book(
        title: row['title'] as String?,
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
        'title': title,
        'subtitle': subtitle,
        'description': description,
        'published_date': publishedDate,
        'isbn': isbn,
        'page_count': pageCount,
        'author_id': authorId,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book.fromRow(json);

  Map<String, dynamic> toJson() => toRow();

  Book copyWith({
    String? title,
    String? subtitle,
    String? description,
    DateTime? publishedDate,
    String? isbn,
    int? pageCount,
    int? authorId,
  }) =>
      Book(
        title: title ?? this.title,
        subtitle: subtitle ?? this.subtitle,
        description: description ?? this.description,
        publishedDate: publishedDate ?? this.publishedDate,
        isbn: isbn ?? this.isbn,
        pageCount: pageCount ?? this.pageCount,
        authorId: authorId ?? this.authorId,
      );

  static final Relation<Book, Author> author = BelongsToRelation<Book, Author>(
    parentTable: 'book',
    childTable: 'author',
    name: 'author',
    parentForeignKey: 'author_id',
    childMeta: AuthorTable.metadata,
  );

  static final Relation<Book, User> reviewers = ManyToManyRelation<Book, User>(
    parentTable: 'book',
    childTable: 'user',
    name: 'reviewers',
    junctionTable: 'book_user',
    junctionParentKey: 'book_id',
    junctionChildKey: 'user_id',
    childMeta: UserTable.metadata,
  );

  static final Relation<Book, Review> reviews = HasManyRelation<Book, Review>(
    parentTable: 'book',
    childTable: 'review',
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
  static const ColumnRef<String?> title = ColumnRef<String?>(
    table: 'book',
    column: 'title',
  );
  static const ColumnRef<String?> subtitle = ColumnRef<String?>(
    table: 'book',
    column: 'subtitle',
  );
  static const ColumnRef<String?> description = ColumnRef<String?>(
    table: 'book',
    column: 'description',
  );
  static const ColumnRef<DateTime?> publishedDate = ColumnRef<DateTime?>(
    table: 'book',
    column: 'published_date',
  );
  static const ColumnRef<String?> isbn = ColumnRef<String?>(
    table: 'book',
    column: 'isbn',
  );
  static const ColumnRef<int?> pageCount = ColumnRef<int?>(
    table: 'book',
    column: 'page_count',
  );
  static const ColumnRef<int?> authorId = ColumnRef<int?>(
    table: 'book',
    column: 'author_id',
  );

  static const TableMeta<Book> metadata = TableMeta<Book>(
    tableName: 'book',
    primaryKey: 'title',
    columnNames: [
      'title',
      'subtitle',
      'description',
      'published_date',
      'isbn',
      'page_count',
      'author_id'
    ],
    fromRow: Book.fromRow,
  );
}

Query<Book> books() => Query<Book>(BookTable.metadata);

class Review with Preloadable {
  final int? id;
  final int? bookId;
  final int? reviewerId;
  final int? rating;
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

  Map<String, dynamic> toJson() => toRow();

  Review copyWith({
    int? id,
    int? bookId,
    int? reviewerId,
    int? rating,
    String? reviewText,
    DateTime? reviewDate,
    bool? isApproved,
    bool? isFlagged,
    bool? isDeleted,
    bool? isSpam,
    bool? isInappropriate,
    bool? isHarmful,
  }) =>
      Review(
        id: id ?? this.id,
        bookId: bookId ?? this.bookId,
        reviewerId: reviewerId ?? this.reviewerId,
        rating: rating ?? this.rating,
        reviewText: reviewText ?? this.reviewText,
        reviewDate: reviewDate ?? this.reviewDate,
        isApproved: isApproved ?? this.isApproved,
        isFlagged: isFlagged ?? this.isFlagged,
        isDeleted: isDeleted ?? this.isDeleted,
        isSpam: isSpam ?? this.isSpam,
        isInappropriate: isInappropriate ?? this.isInappropriate,
        isHarmful: isHarmful ?? this.isHarmful,
      );

  static final Relation<Review, Book> book = BelongsToRelation<Review, Book>(
    parentTable: 'reviews',
    childTable: 'book',
    name: 'book',
    parentForeignKey: 'book_id',
    childMeta: BookTable.metadata,
  );

  static final Relation<Review, User> reviewer =
      BelongsToRelation<Review, User>(
    parentTable: 'reviews',
    childTable: 'user',
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
      'review_text',
      'review_date',
      'is_approved',
      'is_flagged',
      'is_deleted',
      'is_spam',
      'is_inappropriate',
      'is_harmful'
    ],
    fromRow: Review.fromRow,
  );
}

Query<Review> reviews() => Query<Review>(ReviewTable.metadata);
