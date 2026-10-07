# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261007202504_backfill_repo_profile_feature_flags_pattern_for_ruby_projects")

# Re-runs the repository-profile detector for active Ruby projects whose stored
# profile was captured before #4172 added `feature_flags_pattern`, so the
# rollout guard can pick up the right wiring for projects that actually host
# the FeatureFlags API (#4172 transition).
RSpec.describe BackfillRepoProfileFeatureFlagsPatternForRubyProjects, :aggregate_failures do
  let(:migration) { described_class.new }

  # Each project factory fires `after_create_commit :enqueue_knowledge_collection`,
  # which calls `EnqueueKnowledgeCollectionJob.perform_later`. Stub the private
  # method directly so factory creation never enqueues, then stub
  # `perform_later` so only the migration's enqueues are recorded.
  before do
    allow_any_instance_of(Project).to receive(:enqueue_knowledge_collection) # rubocop:disable RSpec/AnyInstance
    allow(EnqueueKnowledgeCollectionJob).to receive(:perform_later)
  end

  it "re-enqueues active Ruby projects whose stored profile lacks the FeatureFlags pattern" do
    ruby_pending = create(:project, active: true, primary_language: "Ruby", repo_profile: {
      "languages" => %w[ruby],
      "feature_flags_pattern" => false
    })

    migration.up

    expect(EnqueueKnowledgeCollectionJob).to have_received(:perform_later).with(ruby_pending.id).once
  end

  it "re-enqueues active Ruby projects identified only by their stored languages array" do
    ruby_languages_only = create(:project, active: true, primary_language: nil, repo_profile: {
      "languages" => %w[ruby javascript]
    })

    migration.up

    expect(EnqueueKnowledgeCollectionJob).to have_received(:perform_later).with(ruby_languages_only.id).once
  end

  it "skips active Ruby projects whose stored profile already records the FeatureFlags pattern" do
    already_flagged = create(:project, active: true, primary_language: "Ruby", repo_profile: {
      "languages" => %w[ruby],
      "feature_flags_pattern" => true
    })

    migration.up

    expect(EnqueueKnowledgeCollectionJob).not_to have_received(:perform_later).with(already_flagged.id)
  end

  it "does not re-enqueue non-Ruby projects even when primary language is unset" do
    python_project = create(:project, active: true, primary_language: "Python", repo_profile: {
      "languages" => %w[python]
    })
    gd_project = create(:project, active: true, primary_language: "GDScript", repo_profile: {
      "languages" => %w[gdscript]
    })

    migration.up

    expect(EnqueueKnowledgeCollectionJob).not_to have_received(:perform_later).with(python_project.id)
    expect(EnqueueKnowledgeCollectionJob).not_to have_received(:perform_later).with(gd_project.id)
  end

  it "does not re-enqueue inactive Ruby projects" do
    inactive_ruby = create(:project, :inactive, primary_language: "Ruby", repo_profile: {
      "languages" => %w[ruby]
    })

    migration.up

    expect(EnqueueKnowledgeCollectionJob).not_to have_received(:perform_later).with(inactive_ruby.id)
  end

  it "re-enqueues active Ruby projects with an empty stored profile" do
    unscanned = create(:project, active: true, primary_language: "Ruby", repo_profile: {})

    migration.up

    expect(EnqueueKnowledgeCollectionJob).to have_received(:perform_later).with(unscanned.id).once
  end

  it "skips projects whose stored profile stores the feature flag pattern in a polyglot mix" do
    polyglot_flagged = create(:project, active: true, primary_language: "Ruby", repo_profile: {
      "languages" => %w[javascript ruby],
      "feature_flags_pattern" => true
    })

    migration.up

    expect(EnqueueKnowledgeCollectionJob).not_to have_received(:perform_later).with(polyglot_flagged.id)
  end
end
