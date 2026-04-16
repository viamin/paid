# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260416050235_move_co_author_trailer_from_projects_to_providers")

# Guards against regressions in the projects → providers trailer migration.
# The migration is destructive in structure (it removes the projects column),
# so these specs verify that existing configured trailers are preserved onto
# the project owner's default subscription provider before column removal.
#
# Model code (Provider) holds the post-migration schema assumption — it has a
# before_validation callback that reads `agent_co_author_trailer`. That means
# spec setup must happen in the post-migration world, using raw SQL to simulate
# the legacy project column while the migration runs. The specs build records
# through factories (post-migration schema), then replay `down` + `up` while
# manually restoring the legacy column state with SQL.
RSpec.describe MoveCoAuthorTrailerFromProjectsToProviders, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:trailer) { "Co-Authored-By: Claude <noreply@anthropic.com>" }

  def restore_legacy_project_column
    connection = ActiveRecord::Base.connection
    return if connection.column_exists?(:projects, :agent_co_author_trailer)

    connection.add_column(:projects, :agent_co_author_trailer, :text)
    connection.remove_column(:providers, :agent_co_author_trailer)
  end

  def run_migration_up
    migration.up
    Project.reset_column_information
    Provider.reset_column_information
  end

  # Ensure the schema ends each example in its post-migration state so the
  # rest of the suite is unaffected.
  after do
    unless ActiveRecord::Base.connection.column_exists?(:providers, :agent_co_author_trailer)
      migration.up
    end
    Project.reset_column_information
    Provider.reset_column_information
  end

  it "copies a project trailer onto the creator's default subscription provider" do
    project = create(:project)
    owner = project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")

    restore_legacy_project_column
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE projects SET agent_co_author_trailer = ? WHERE id = ?", trailer, project.id
      ])
    )

    run_migration_up

    expect(provider.reload.agent_co_author_trailer).to eq(trailer)
    expect(ActiveRecord::Base.connection.column_exists?(:projects, :agent_co_author_trailer)).to be false
  end

  it "leaves providers untouched when no project has a configured trailer" do
    project = create(:project)
    owner = project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")

    restore_legacy_project_column
    run_migration_up

    expect(provider.reload.agent_co_author_trailer).to be_nil
  end

  it "picks the most recently updated project's trailer when the owner has multiple" do
    older_project = create(:project)
    owner = older_project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")
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

    expect(provider.reload.agent_co_author_trailer).to eq(trailer)
  end

  it "ignores blank/whitespace-only trailers" do
    project = create(:project)
    owner = project.effective_owner
    provider = owner.providers.find_by!(provider_key: "claude", auth_type: "subscription")

    restore_legacy_project_column
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

    restore_legacy_project_column
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
