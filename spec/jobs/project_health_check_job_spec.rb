# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectHealthCheckJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before do
    allow(HealthChecks::Cache).to receive(:write)
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
  end

  it "writes the Coordinator result to the cache" do
    described_class.perform_now(project.id)

    expect(HealthChecks::Cache).to have_received(:write) do |proj, result|
      expect(proj.id).to eq(project.id)
      expect(result).to be_a(HealthChecks::Result)
      expect(result.findings).to be_an(Array)
    end
  end

  it "emits a structured completion log with findings count and duration" do
    allow(Rails.logger).to receive(:info)

    described_class.perform_now(project.id)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "project_health.check_completed",
        project_id: project.id,
        findings_count: an_instance_of(Integer),
        duration_ms: an_instance_of(Integer)
      )
    )
  end

  it "broadcasts the fresh result via Turbo Streams so the page auto-refreshes" do
    described_class.perform_now(project.id)

    expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
      [ project, :health_checks ],
      hash_including(
        target: "health_check_result",
        partial: "projects/health_check/result"
      )
    )
  end

  it "discards silently when the project no longer exists" do
    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(HealthChecks::Cache).not_to have_received(:write)
  end
end
