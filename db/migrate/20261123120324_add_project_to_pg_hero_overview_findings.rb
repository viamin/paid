class AddProjectToPgHeroOverviewFindings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :pg_hero_overview_findings, :project, null: false, index: false
    remove_index :pg_hero_overview_findings, name: "index_pghero_overview_findings_on_database_and_finding_key", algorithm: :concurrently
    add_index :pg_hero_overview_findings, [ :project_id, :database, :finding_key ], unique: true,
      name: "index_pghero_overview_findings_on_project_database_and_finding_key", algorithm: :concurrently
  end
end
