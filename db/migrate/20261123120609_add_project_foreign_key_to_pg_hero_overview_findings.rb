class AddProjectForeignKeyToPgHeroOverviewFindings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_foreign_key :pghero_overview_findings, :projects, validate: false
  end
end
