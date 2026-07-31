-- gisila-generated migration: up
-- DO NOT EDIT - regenerate via `dart run build_runner build`

BEGIN;

CREATE TYPE "review_verdict" AS ENUM ('pending', 'approved', 'rejected');

CREATE TABLE "authors" (
  "id" BIGSERIAL PRIMARY KEY,
  "first_name" VARCHAR(255) NOT NULL,
  "last_name" VARCHAR(255),
  "email" VARCHAR(255) NOT NULL UNIQUE
);


CREATE TABLE "books" (
  "id" BIGSERIAL PRIMARY KEY,
  "title" VARCHAR(255) NOT NULL UNIQUE,
  "subtitle" VARCHAR(255),
  "description" TEXT,
  "published_date" DATE,
  "isbn" VARCHAR(255) UNIQUE,
  "page_count" INTEGER,
  "author_id" BIGINT
);


CREATE TABLE "places" (
  "id" BIGSERIAL PRIMARY KEY,
  "name" VARCHAR(255) NOT NULL,
  "location" POINT NOT NULL,
  "bounds" BOX
);


CREATE TABLE "reviews" (
  "id" BIGSERIAL PRIMARY KEY,
  "book_id" BIGINT,
  "reviewer_id" BIGINT,
  "rating" INTEGER,
  "verdict" "review_verdict" NOT NULL DEFAULT 'pending'::review_verdict,
  "tags" VARCHAR(255)[] DEFAULT '{}'::varchar[],
  "review_text" TEXT,
  "review_date" TIMESTAMP WITH TIME ZONE NOT NULL,
  "is_approved" BOOLEAN NOT NULL,
  "is_flagged" BOOLEAN NOT NULL,
  "is_deleted" BOOLEAN NOT NULL,
  "is_spam" BOOLEAN NOT NULL,
  "is_inappropriate" BOOLEAN NOT NULL,
  "is_harmful" BOOLEAN NOT NULL,
  CONSTRAINT "reviews_rating_check" CHECK (rating >= 1 AND rating <= 5)
);


CREATE TABLE "users" (
  "id" BIGSERIAL PRIMARY KEY,
  "first_name" VARCHAR(255) NOT NULL,
  "last_name" VARCHAR(255),
  "email" VARCHAR(255) NOT NULL UNIQUE,
  "password" VARCHAR(255) NOT NULL,
  "date_joined" TIMESTAMP WITH TIME ZONE NOT NULL
);


CREATE TABLE "books_users" (
  "books_id" BIGINT NOT NULL,
  "users_id" BIGINT NOT NULL,
  "created_at" TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("books_id", "users_id"),
  FOREIGN KEY ("books_id") REFERENCES "books" ("id") ON DELETE CASCADE,
  FOREIGN KEY ("users_id") REFERENCES "users" ("id") ON DELETE CASCADE
);

ALTER TABLE "books" ADD CONSTRAINT "books_author_fkey" FOREIGN KEY ("author_id") REFERENCES "authors" ("id") ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "reviews" ADD CONSTRAINT "reviews_book_fkey" FOREIGN KEY ("book_id") REFERENCES "books" ("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "reviews" ADD CONSTRAINT "reviews_reviewer_fkey" FOREIGN KEY ("reviewer_id") REFERENCES "users" ("id") ON DELETE SET NULL ON UPDATE CASCADE;

CREATE INDEX "idx_books_author_id" ON "books" ("author_id");

CREATE INDEX "idx_reviews_book_id" ON "reviews" ("book_id");
CREATE INDEX "idx_review_book" ON "reviews" ("book_id");
CREATE INDEX "idx_review_reviewer" ON "reviews" ("reviewer_id");

COMMIT;
