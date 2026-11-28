# frozen_string_literal: true

# @spec RAILS-CONTROL-PLANE-033 RAILS-CONTROL-PLANE-034
class CreatePgHeroOverviewRepairs < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :pghero_overview_repairs, if_not_exists: true, comment: "Project-scoped development database repair ownership." do |t|
      t.bigint :project_id, null: false
      t.text :database, null: false
      t.text :repair_key, null: false
      t.text :title, null: false
      t.text :instructions, null: false, default: ""
      t.text :rationale, null: false, default: ""
      t.bigint :github_issue_number
      t.bigint :github_pr_number
      t.boolean :managed_issue, null: false, default: true
      t.datetime :resolved_at
      t.datetime :issue_last_updated_at
      t.timestamps
    end
    add_index :pghero_overview_repairs, [ :project_id, :database, :repair_key ], unique: true,
      name: "index_pghero_repairs_on_project_database_key", if_not_exists: true
    add_foreign_key :pghero_overview_repairs, :projects, validate: false
    add_reference :pghero_overview_findings, :repair, index: false
    add_index :pghero_overview_findings, :repair_id, algorithm: :concurrently
    add_foreign_key :pghero_overview_findings, :pghero_overview_repairs, column: :repair_id, validate: false
    add_column :pghero_overview_findings, :observation, :jsonb, null: false, default: {}
  end
end
