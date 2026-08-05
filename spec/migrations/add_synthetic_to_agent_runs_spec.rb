# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260805045119_add_synthetic_to_agent_runs")

RSpec.describe AddSyntheticToAgentRuns, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    truncate_agent_run_data
    example.run
  ensure
    truncate_agent_run_data
  end

  # @spec LIVE-PREVIEW-003
  it "repairs historical preview-run counters while backfilling the synthetic flag" do
    project = create(:project)

    preview_completed = create(:agent_run, :completed, :internal_agent, project: project,
      external_metadata: { "preview_session" => true })
    preview_running = create(:agent_run, :running, :internal_agent, project: project,
      external_metadata: { "preview_session" => true })
    real_completed = create(:agent_run, :completed, project: project)

    preview_completed.update_columns(synthetic: false)
    preview_running.update_columns(synthetic: false)
    project.update_columns(agent_runs_count: 3, completed_agent_runs_count: 2)

    migration.up

    expect(preview_completed.reload).to be_synthetic
    expect(preview_running.reload).to be_synthetic
    expect(real_completed.reload).not_to be_synthetic
    expect(project.reload.agent_runs_count).to eq(1)
    expect(project.reload.completed_agent_runs_count).to eq(1)
  end

  # @spec LIVE-PREVIEW-003
  it "re-runs safely when the column already exists but counters still need repair" do
    project = create(:project)
    preview_run = create(:agent_run, :completed, :internal_agent, project: project,
      external_metadata: { "preview_session" => true }, synthetic: false)

    project.update_columns(agent_runs_count: 1, completed_agent_runs_count: 1)

    expect { migration.up }.not_to raise_error

    expect(preview_run.reload).to be_synthetic
    expect(project.reload.agent_runs_count).to eq(0)
    expect(project.reload.completed_agent_runs_count).to eq(0)
  end

  private

  def truncate_agent_run_data
    connection.execute("DELETE FROM agent_run_logs")
    connection.execute("DELETE FROM agent_runs")
    connection.execute("DELETE FROM issues")
    connection.execute("DELETE FROM projects")
    connection.execute("DELETE FROM runners")
    connection.execute("DELETE FROM runner_states")
    connection.execute("DELETE FROM github_tokens")
    connection.execute("DELETE FROM user_settings")
    connection.execute("DELETE FROM tenant_settings")
    connection.execute("DELETE FROM account_memberships")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM accounts")
  end
end
