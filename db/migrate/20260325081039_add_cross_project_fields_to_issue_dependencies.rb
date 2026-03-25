# frozen_string_literal: true

class AddCrossProjectFieldsToIssueDependencies < ActiveRecord::Migration[8.1]
  def change
    change_column_null :issue_dependencies, :depends_on_issue_id, true

    add_column :issue_dependencies, :depends_on_owner, :string
    add_column :issue_dependencies, :depends_on_repo, :string
    add_column :issue_dependencies, :depends_on_number, :integer

    add_index :issue_dependencies,
              [ :issue_id, :depends_on_owner, :depends_on_repo, :depends_on_number ],
              unique: true,
              where: "depends_on_owner IS NOT NULL",
              name: "idx_issue_deps_external_unique"
  end
end
