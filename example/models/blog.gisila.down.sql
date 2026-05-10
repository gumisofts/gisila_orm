-- gisila-generated migration: down
-- DO NOT EDIT - regenerate via `dart run build_runner build`

BEGIN;

ALTER TABLE "reviews" DROP CONSTRAINT IF EXISTS "reviews_book_fkey";
ALTER TABLE "reviews" DROP CONSTRAINT IF EXISTS "reviews_reviewer_fkey";
ALTER TABLE "book" DROP CONSTRAINT IF EXISTS "book_author_fkey";
DROP TABLE IF EXISTS "book_user" CASCADE;
DROP TABLE IF EXISTS "reviews" CASCADE;
DROP TABLE IF EXISTS "book" CASCADE;
DROP TABLE IF EXISTS "author" CASCADE;
DROP TABLE IF EXISTS "user" CASCADE;

COMMIT;
