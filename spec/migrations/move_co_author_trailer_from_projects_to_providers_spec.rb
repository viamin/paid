# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260416050235_move_co_author_trailer_from_projects_to_providers")

# Guards against regressions in the projects → runners trailer migration.
# The migration is destructive in structure (it removes the projects column),
# so these specs verify that existing configured trailers are preserved onto
# the project owner's default subscription runner before column removal.
#
# Model code (Runner) holds the post-migration schema assumption — it has a
# before_validation callback that reads `agent_co_author_trailer`. That means
# spec setup must happen in the post-migration world, using raw SQL to add and
# populate the legacy project column while the migration runs. Keep the runner
# column present because current model callbacks read it during factory setup and
# after-commit broadcasts elsewhere in the suite.
RSpec.describe MoveCoAuthorTrailerFromProjectsToProviders, :aggregate_failures do
  # DDL operations (add_column / remove_column) acquire AccessExclusiveLock
  # which deadlocks with transactional fixtures. Disable transactional tests
  # and truncate tables manually after each example.
  self.use_transactional_tests = false

  # The original migration body still references the pre-rename `:providers`
  # table, so this regression spec remains pending until the migration coverage
  # is rewritten around the renamed `:runners` schema.
  before { skip "pending rewrite against renamed :runners table (#2083)" }

  let(:migration) { described_class.new }
  let(:trailer) { "Co-Authored-By: Claude <noreply@anthropic.com>" }

  def restore_legacy_project_column
    connection = ActiveRecord::Base.connection
    return if connection.column_exists?(:projects, :agent_co_author_trailer)

    connection.add_column(:projects, :agent_co_author_trailer, :text)
  end

  def run_migration_up
    migration.up
    Project.reset_column_information
    Runner.reset_column_information
  end

  include MigrationSpecHelpers

  # Ensure the schema ends each example in its post-migration state so the
  # rest of the suite is unaffected. Also clean up data created without
  # transactional rollback.
  after do
    connection = ActiveRecord::Base.connection
    if connection.data_source_exists?(:runners) &&
        !connection.column_exists?(:runners, :agent_co_author_trailer)
      connection.add_column(:runners, :agent_co_author_trailer, :text)
    end
    if connection.column_exists?(:projects, :agent_co_author_trailer)
      connection.remove_column(:projects, :agent_co_author_trailer)
    end
    Project.reset_column_information
    Runner.reset_column_information
    truncate_migration_test_data
  end

  it "copies a project trailer onto the creator's default subscription runner" do
    project = create(:project)
    owner = project.effective_owner
    runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")

    restore_legacy_project_column
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", trailer, project.id
      ])
    )

    run_migration_up

    expect(runner.reload.agent_co_author_trailer).to eq(trailer)
    expect(ActiveRecord::Base.connection.column_exists?(:projects, :agent_co_author_trailer)).to be false
  end

  it "leaves runners untouched when no project has a configured trailer" do
    project = create(:project)
    owner = project.effective_owner
    runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")

    restore_legacy_project_column
    run_migration_up

    expect(runner.reload.agent_co_author_trailer).to be_nil
  end

  it "picks the most recently updated project's trailer when the owner has multiple" do
    older_project = create(:project)
    owner = older_project.effective_owner
    runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
    newer_project = create(:project, account: older_project.account, created_by: owner)

    restore_legacy_project_column
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ?, updated_at = ? WHERE id = ?",
        "Co-Authored-By: Old <old@example.com>", 2.days.ago, older_project.id
      ])
    )
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ?, updated_at = ? WHERE id = ?",
        trailer, 1.day.ago, newer_project.id
      ])
    )

    run_migration_up

    expect(runner.reload.agent_co_author_trailer).to eq(trailer)
  end

  it "ignores blank/whitespace-only trailers" do
    project = create(:project)
    owner = project.effective_owner
    runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")

    restore_legacy_project_column
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", "   ", project.id
      ])
    )

    run_migration_up

    expect(runner.reload.agent_co_author_trailer).to be_nil
  end

  it "prefers the claude subscription runner when the owner has multiple runners" do
    project = create(:project)
    owner = project.effective_owner
    claude_runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
    other_runner = owner.runners.create!(
      runner_key: "codex",
      auth_type: "subscription",
      enabled_for_agent_runs: false
    )

    restore_legacy_project_column
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", trailer, project.id
      ])
    )

    run_migration_up

    expect(claude_runner.reload.agent_co_author_trailer).to eq(trailer)
    expect(other_runner.reload.agent_co_author_trailer).to be_nil
  end
end
