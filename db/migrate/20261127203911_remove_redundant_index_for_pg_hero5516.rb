# frozen_string_literal: true

# idx_on_project_id_alert_number_4aee5d2590 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5516 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :dependabot_alert_coverages, name: "index_dependabot_alert_coverages_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :dependabot_alert_coverages, [ :project_id ],
      name: "index_dependabot_alert_coverages_on_project_id", algorithm: :concurrently
  end
end
