# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::ApplicationDiagnostics do
  # @spec APP-DIAGNOSTICS-001
  # @spec APP-DIAGNOSTICS-002
  let(:agent_run) { create(:agent_run, :with_git_context) }

  it "returns redacted bounded application logs and run-scoped metric observations" do
    agent_run.update!(verification_result: { "app_log_tail" => "boot token=super-secret-value" })
    create(:container_metric, agent_run:, recorded_at: 2.minutes.ago, cpu_percent: 10.5, memory_bytes: 2_048)

    result = described_class.call(agent_run:, lookback_seconds: 3_600, limit: 1)

    expect(result.fetch("logs").fetch("entries").first.fetch("content")).to include("[REDACTED")
    expect(result.fetch("metrics").fetch("samples")).to contain_exactly(include("cpu_percent" => 10.5))
    expect(result.fetch("provenance")).to include("agent_run_id" => agent_run.id, "project_id" => agent_run.project_id)
  end

  # @spec APP-DIAGNOSTICS-002
  it "advertises every container metric even when the oldest sample omits pids" do
    create(:container_metric, agent_run:, recorded_at: 2.minutes.ago, pids_count: nil)
    create(:container_metric, agent_run:, recorded_at: 1.minute.ago, pids_count: 3)

    result = described_class.call(agent_run:)

    expect(result.dig("metrics", "metric_names")).to include("pids_count")
  end

  it "reports unavailable evidence instead of treating missing telemetry as success" do
    result = described_class.call(agent_run:)

    expect(result.dig("logs", "status")).to eq("unavailable")
    expect(result.dig("metrics", "status")).to eq("unavailable")
  end

  it "does not return observations from another run" do
    other_run = create(:agent_run, :with_git_context, project: agent_run.project)
    create(:container_metric, agent_run: other_run, recorded_at: 1.minute.ago)

    expect(described_class.call(agent_run:).dig("metrics", "status")).to eq("unavailable")
  end

  # @spec APP-DIAGNOSTICS-001
  it "propagates the persisted truncation marker so callers know the tail is bounded" do
    agent_run.update!(verification_result: {
      "app_log_tail" => "truncated tail",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z",
      "app_log_truncated" => true
    })

    result = described_class.call(agent_run:)

    expect(result.dig("logs", "entries").first).to include("truncated" => true)
  end
end
