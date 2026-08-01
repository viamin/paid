# frozen_string_literal: true

# Removes the orphaned `fair_queue_across_projects` column. It was added with
# the intent of toggling cross-project fair-share vs. strict priority ordering,
# but was never wired into `AgentRun::QUEUE_ORDER` (or anywhere else) and never
# exposed in the UI, so it has had no effect since it was introduced.
#
# The real, account-level solution is tracked in RDR-050. See that RDR before
# reintroducing any fairness-mode column — it belongs on `tenant_settings`
# (account-scoped), not `user_settings`.
class RemoveFairQueueAcrossProjectsFromUserSettings < ActiveRecord::Migration[8.1]
  # strong_migrations flags remove_column because a running app process may
  # still have the column cached. This column is unused (zero references in
  # app/config/spec), so there is no attribute-caching hazard — safe to drop.
  def change
    return unless column_exists?(:user_settings, :fair_queue_across_projects, :boolean)

    safety_assured do
      remove_column :user_settings, :fair_queue_across_projects, :boolean,
        default: true, null: false
    end
  end
end
