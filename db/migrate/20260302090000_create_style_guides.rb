# frozen_string_literal: true

class CreateStyleGuides < ActiveRecord::Migration[8.1]
  def change
    create_table :style_guides do |t|
      t.bigint :account_id
      t.bigint :project_id
      t.string :name, limit: 255, null: false
      t.text :raw_content, null: false
      t.text :compressed_content
      t.jsonb :compression_metadata, default: {}, null: false
      t.boolean :active, default: true, null: false
      t.string :language, limit: 50

      t.timestamps
    end

    add_index :style_guides, :account_id
    add_index :style_guides, :project_id
    add_index :style_guides, :active
    add_index :style_guides, :language
    add_index :style_guides, [ :name, :account_id ],
      name: "index_style_guides_on_name_account",
      unique: true,
      where: "(account_id IS NOT NULL) AND (project_id IS NULL)"
    add_index :style_guides, [ :name, :project_id ],
      name: "index_style_guides_on_name_project",
      unique: true,
      where: "(project_id IS NOT NULL)"
    add_index :style_guides, :name,
      name: "index_style_guides_on_name_global",
      unique: true,
      where: "(account_id IS NULL) AND (project_id IS NULL)"

    add_foreign_key :style_guides, :accounts, on_delete: :cascade
    add_foreign_key :style_guides, :projects, on_delete: :cascade

    add_check_constraint :style_guides,
      "project_id IS NULL OR account_id IS NOT NULL",
      name: "chk_style_guides_scope_consistency"
  end
end
