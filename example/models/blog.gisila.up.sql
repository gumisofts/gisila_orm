-- gisila-generated migration: up
-- DO NOT EDIT - regenerate via `dart run build_runner build`

BEGIN;

CREATE TABLE "user" (
  "id" BIGSERIAL PRIMARY KEY,
  "first_name" VARCHAR(255) NOT NULL,
  "last_name" VARCHAR(255),
  "email" VARCHAR(255) NOT NULL UNIQUE,
  "password" VARCHAR(255) NOT NULL,
  "date_joined" TIMESTAMP WITH TIME ZONE NOT NULL
);


CREATE TABLE "author" (
  "id" BIGSERIAL PRIMARY KEY,
  "first_name" VARCHAR(255) NOT NULL,
  "last_name" VARCHAR(255),
  "email" VARCHAR(255) NOT NULL UNIQUE
);


CREATE TABLE "book" (
  "title" VARCHAR(255) PRIMARY KEY,
  "subtitle" VARCHAR(255),
  "description" TEXT,
  "published_date" DATE,
  "isbn" VARCHAR(255) UNIQUE,
  "page_count" INTEGER,
  "author_id" INTEGER
);


CREATE TABLE "reviews" (
  "id" BIGSERIAL PRIMARY KEY,
  "book_id" INTEGER,
  "reviewer_id" INTEGER,
  "rating" INTEGER,
  "review_text" TEXT,
  "review_date" TIMESTAMP WITH TIME ZONE NOT NULL,
  "is_approved" BOOLEAN NOT NULL,
  "is_flagged" BOOLEAN NOT NULL,
  "is_deleted" BOOLEAN NOT NULL,
  "is_spam" BOOLEAN NOT NULL,
  "is_inappropriate" BOOLEAN NOT NULL,
  "is_harmful" BOOLEAN NOT NULL
);


CREATE TABLE "book_user" (
  "book_id" INTEGER NOT NULL,
  "user_id" INTEGER NOT NULL,
  "created_at" TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("book_id", "user_id"),
  FOREIGN KEY ("book_id") REFERENCES "book" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("user_id") REFERENCES "user" ("id") ON DELETE CASCADE
);

ALTER TABLE "book" ADD CONSTRAINT "book_author_fkey" FOREIGN KEY ("author_id") REFERENCES "author" ("id") ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "reviews" ADD CONSTRAINT "reviews_book_fkey" FOREIGN KEY ("book_id") REFERENCES "book" ("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "reviews" ADD CONSTRAINT "reviews_reviewer_fkey" FOREIGN KEY ("reviewer_id") REFERENCES "user" ("id") ON DELETE SET NULL ON UPDATE CASCADE;

CREATE INDEX "idx_book_author_id" ON "book" ("author_id");

CREATE INDEX "idx_reviews_book_id" ON "reviews" ("book_id");
CREATE INDEX "idx_review_book" ON "reviews" ("book");
CREATE INDEX "idx_review_reviewer" ON "reviews" ("reviewer");

COMMIT;
