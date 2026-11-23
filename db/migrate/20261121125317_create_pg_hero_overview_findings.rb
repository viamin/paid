# frozen_string_literal: true

# @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-028
class CreatePgHeroOverviewFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :pghero_overview_findings, comment: "Development PgHero Overview scan state; system-wide, not tenant-owned." do |t|
      t.text :database, null: false
      t.text :finding_key, null: false
      t.text :finding_type, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :consecutive_observations, null: false, default: 0
      t.bigint :github_issue_number
      t.datetime :issue_last_updated_at
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :pghero_overview_findings, [ :database, :finding_key ], unique: true,
      name: "index_pghero_overview_findings_on_database_and_finding_key"
  end
end
