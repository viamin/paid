# frozen_string_literal: true

# @spec RAILS-CONTROL-PLANE-020 RAILS-CONTROL-PLANE-021
class CreatePgHeroHistory < ActiveRecord::Migration[8.1]
  def change
    create_table :pghero_queries, comment: "Normalized SQL for development database diagnostics; system-wide, not tenant-owned." do |t|
      t.text :query
    end
    add_index :pghero_queries, :query, using: :hash

    create_table :pghero_query_stats, comment: "Development PgHero interval samples, retained for 14 days." do |t|
      t.text :database
      t.text :user
      t.references :query, foreign_key: { to_table: :pghero_queries }
      t.bigint :query_hash
      t.float :total_time, comment: "Combined planning and execution milliseconds."
      t.bigint :calls
      t.timestamp :captured_at
    end
    add_index :pghero_query_stats, [ :database, :captured_at ]

    create_table :pghero_space_stats, comment: "Development PgHero daily relation sizes, retained for 14 days." do |t|
      t.text :database
      t.text :schema
      t.text :relation
      t.bigint :size
      t.timestamp :captured_at
    end
    add_index :pghero_space_stats, [ :database, :captured_at ]
  end
end
