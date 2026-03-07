# frozen_string_literal: true

class CreateIssueDependencies < ActiveRecord::Migration[8.1]
  def change
    create_table :issue_dependencies do |t|
      t.references :issue, null: false, foreign_key: { on_delete: :cascade }
      t.references :depends_on_issue, null: false, foreign_key: { to_table: :issues, on_delete: :cascade }

      t.timestamps
    end

    add_index :issue_dependencies, [ :issue_id, :depends_on_issue_id ], unique: true,
              name: "idx_issue_dependencies_unique"
  end
end
