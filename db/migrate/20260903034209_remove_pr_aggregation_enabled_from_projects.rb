# frozen_string_literal: true

class RemovePrAggregationEnabledFromProjects < ActiveRecord::Migration[8.1]
  def up
    # Compatibility release: older web/job processes still write
    # `projects.pr_aggregation_enabled` during a normal migrate-before-restart
    # deploy, and a rollback needs the persisted value intact. The column
    # is already ignored by the current model (see `Project.ignored_columns`),
    # so this release is a no-op; drop the column in a later cleanup
    # release. See DropLanguageProfileFromProjects for the same pattern.
  end

  def down
    # No-op: up intentionally preserves the legacy column for one more
    # compatibility release, so rollback has nothing to recreate.
  end
end
