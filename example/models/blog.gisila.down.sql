-- gisila-generated migration: down
-- DO NOT EDIT - regenerate via `dart run build_runner build`

BEGIN;

ALTER TABLE "reviews" DROP CONSTRAINT IF EXISTS "reviews_book_fkey";
ALTER TABLE "reviews" DROP CONSTRAINT IF EXISTS "reviews_reviewer_fkey";
ALTER TABLE "books" DROP CONSTRAINT IF EXISTS "books_author_fkey";
DROP TABLE IF EXISTS "books_users" CASCADE;
DROP TABLE IF EXISTS "users" CASCADE;
DROP TABLE IF EXISTS "reviews" CASCADE;
DROP TABLE IF EXISTS "places" CASCADE;
DROP TABLE IF EXISTS "books" CASCADE;
DROP TABLE IF EXISTS "authors" CASCADE;
DROP TYPE IF EXISTS "review_verdict";

COMMIT;
