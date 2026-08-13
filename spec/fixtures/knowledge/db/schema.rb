# frozen_string_literal: true

ActiveRecord::Schema[7.1].define(version: 2024_01_15_000000) do
  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "name"
    t.string "encrypted_password", null: false
    t.boolean "admin", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "email" ], name: "index_users_on_email", unique: true
  end

  create_table "posts", force: :cascade do |t|
    t.string "title", null: false
    t.text "body"
    t.bigint "user_id", null: false
    t.string "status", default: "draft"
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "user_id" ], name: "index_posts_on_user_id"
    t.index [ "status", "published_at" ], name: "index_posts_on_status_and_published_at"
  end

  create_table "comments", force: :cascade do |t|
    t.text "body", null: false
    t.bigint "post_id", null: false
    t.bigint "user_id", null: false
    t.string "commentable_type"
    t.bigint "commentable_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "commentable_type", "commentable_id" ], name: "index_comments_on_commentable"
    t.index [ "post_id" ], name: "index_comments_on_post_id"
    t.index [ "user_id" ], name: "index_comments_on_user_id"
  end

  create_table "ar_internal_metadata", id: :string, force: :cascade do |t|
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "schema_migrations", id: false, force: :cascade do |t|
    t.string "version", null: false
    t.index [ "version" ], name: "unique_schema_migrations", unique: true
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "name" ], name: "index_tags_on_name", unique: true
  end

  add_foreign_key "posts", "users"
  add_foreign_key "comments", "posts"
  add_foreign_key "comments", "users"
end
