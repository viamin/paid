# frozen_string_literal: true

class AddOpenAlertLookupIndexToDependabotAlertCoverages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    return if index_exists?(
      :dependabot_alert_coverages,
      [ :project_id, :alert_state, :last_detected_at ],
      name: "idx_dependabot_coverages_project_alert_state_detected"
    )

    add_index :dependabot_alert_coverages,
      [ :project_id, :alert_state, :last_detected_at ],
      name: "idx_dependabot_coverages_project_alert_state_detected",
      algorithm: :concurrently,
      comment: "Supports projects#show listing of open Dependabot alerts (alert_state='open' filtered by project_id, ordered by last_detected_at desc) so the query stays a cheap index scan instead of growing linearly with backlog size."
  end
end
