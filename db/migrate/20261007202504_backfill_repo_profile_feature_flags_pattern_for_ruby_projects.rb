# frozen_string_literal: true

# Re-enqueues EnqueueKnowledgeCollectionJob for active Ruby projects so the
# repository profile picks up the `feature_flags_pattern` field that
# `Projects::DetectRepoProfile` started recording with #4172.
#
# Before this PR, every project created before deploy kept a stored
# `repo_profile` without that key, so `Features::FlagGuardPattern.applicable?`
# stayed false on the flagship Rails repo this guard was designed for and the
# RDR output contract silently dropped its `FeatureFlags::DEFINITIONS` /
# `FeatureFlags.enabled?` checks. Re-running the detector restores the key for
# any project whose repository actually implements the API.
#
# Only Ruby projects are re-scanned: the FeatureFlags API path
# (`app/services/feature_flags.rb`) is Ruby-specific, so non-Ruby projects
# always render the repository-native guard regardless of scan evidence.
# Projects whose stored profile already records `feature_flags_pattern: true`
# are skipped — the detector would just confirm what we already know.
#
# Re-running this migration is safe: the job is idempotent and skips projects
# already correctly flagged.
class BackfillRepoProfileFeatureFlagsPatternForRubyProjects < ActiveRecord::Migration[8.1]
  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  def up
    TenantContext.with_system_access do
      MigrationProject.unscoped
        .where(active: true)
        .where(
          "(repo_profile -> 'languages') ? 'ruby' OR lower(primary_language) = 'ruby'"
        )
        .where("COALESCE((repo_profile ->> 'feature_flags_pattern')::boolean, false) IS DISTINCT FROM TRUE")
        .find_each(batch_size: 200) do |project|
          EnqueueKnowledgeCollectionJob.perform_later(project.id)
        end
    end
  end

  def down; end
end
