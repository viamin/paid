# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260416050235_move_co_author_trailer_from_projects_to_providers")

# Guards against regressions in the projects → providers trailer migration.
# The migration is destructive in structure (it removes the projects column),
# so these specs verify that existing configured trailers are preserved onto
# the project owner's default subscription provider before column removal.
#
# Model code (Provider) holds the post-migration schema assumption — it has a
# before_validation callback that reads `agent_co_author_trailer`. Keep the
# provider column present because current model callbacks read it during factory
# setup and after-commit broadcasts elsewhere in the suite. The legacy projects
# column is added for each example and the destructive removal is stubbed while
# asserting the migration calls it.
RSpec.describe MoveCoAuthorTrailerFromProjectsToProviders, :aggregate_failures do
  # This spec writes outside transactional fixtures so the temporary legacy
  # column remains available for every example.
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:trailer) { "Co-Authored-By: Claude <noreply@anthropic.com>" }

  before do
    connection = ActiveRecord::Base.connection
    connection.add_column(:projects, :agent_co_author_trailer, :text) unless connection.column_exists?(:projects, :agent_co_author_trailer)
    Project.reset_column_information
    Provider.reset_column_information
  end

  def run_migration_up
    allow(migration).to receive(:remove_column)
    migration.up
    expect(migration).to have_received(:remove_column).with(:projects, :agent_co_author_trailer, if_exists: true)
    Project.reset_column_information
    Provider.reset_column_information
  end

  # Clean up data that was not rolled back by transactional fixtures. Keep
  # deletes ordered from child tables to parent tables so this does not need
  # disable_referential_integrity, which takes broad locks across the suite.
  after do
    connection = ActiveRecord::Base.connection
    %w[projects providers provider_states account_memberships github_tokens users accounts].each do |table|
      connection.execute("DELETE FROM #{table}")
    end
    connection.remove_column(:projects, :agent_co_author_trailer, if_exists: true)
    Project.reset_column_information
    Provider.reset_column_information
  end

  it "copies a project trailer onto the creator's default subscription provider" do
    project = create(:project)
    owner = project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", trailer, project.id
      ])
    )

    run_migration_up

    expect(provider.reload.agent_co_author_trailer).to eq(trailer)
  end

  it "leaves providers untouched when no project has a configured trailer" do
    project = create(:project)
    owner = project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")

    run_migration_up

    expect(provider.reload.agent_co_author_trailer).to be_nil
  end

  it "picks the most recently updated project's trailer when the owner has multiple" do
    older_project = create(:project)
    owner = older_project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")
    newer_project = create(:project, account: older_project.account, created_by: owner)

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

    expect(provider.reload.agent_co_author_trailer).to eq(trailer)
  end

  it "ignores blank/whitespace-only trailers" do
    project = create(:project)
    owner = project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", "   ", project.id
      ])
    )

    run_migration_up

    expect(provider.reload.agent_co_author_trailer).to be_nil
  end

  it "prefers the claude subscription provider when the owner has multiple providers" do
    project = create(:project)
    owner = project.effective_owner
    claude_provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")
    other_provider = owner.providers.create!(
      provider_key: "codex",
      auth_type: "subscription",
      enabled_for_agent_runs: false
    )

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", trailer, project.id
      ])
    )

    run_migration_up

    expect(claude_provider.reload.agent_co_author_trailer).to eq(trailer)
    expect(other_provider.reload.agent_co_author_trailer).to be_nil
  end
end
