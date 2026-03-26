# frozen_string_literal: true

class CreateProjectVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :project_versions do |t|
      t.bigint :project_id, null: false
      t.string :commit_sha, limit: 40, null: false
      t.string :parent_sha, limit: 40
      t.string :branch, null: false, default: "main"
      t.datetime :committed_at
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :project_versions, [ :project_id, :commit_sha ], unique: true
    add_index :project_versions, [ :project_id, :committed_at ]
    add_foreign_key :project_versions, :projects
  end
end
