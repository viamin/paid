# frozen_string_literal: true

class RemovePrAggregationEnabledFromProjects < ActiveRecord::Migration[8.1]
  def up
    # Compatibility release: older web/job processes still read/write
    # `projects.pr_aggregation_enabled` during a normal migrate-before-restart
    # deploy, and a rollback needs the persisted value intact. Keep the
    # column until a later cleanup release can remove it safely.
    # TODO(#3815): drop projects.pr_aggregation_enabled and remove the
    # EXCLUDED_ATTRIBUTE_COLUMNS exemption in Configuration::Profiles::Settings.
  end

  def down
    # No-op: up intentionally preserves the legacy column for one more
    # compatibility release, so rollback has nothing to recreate.
  end
end
