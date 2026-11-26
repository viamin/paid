# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260805045119_add_synthetic_to_agent_runs")

# @spec TEST-SUITE-027
RSpec.describe AddSyntheticToAgentRuns, :aggregate_failures do
  let(:migration) { described_class.new }

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
end
