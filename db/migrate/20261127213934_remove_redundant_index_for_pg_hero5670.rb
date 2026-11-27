# frozen_string_literal: true

# idx_page_load_findings_pr_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5670 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :page_load_regression_findings, name: "index_page_load_regression_findings_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :page_load_regression_findings, [ :project_id ],
      name: "index_page_load_regression_findings_on_project_id", algorithm: :concurrently
  end
end
