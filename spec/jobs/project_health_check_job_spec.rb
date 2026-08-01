# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectHealthCheckJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  it "writes the Coordinator result to the cache" do
    allow(HealthChecks::Cache).to receive(:write)

    described_class.perform_now(project.id)

    expect(HealthChecks::Cache).to have_received(:write) do |proj, result|
      expect(proj.id).to eq(project.id)
      expect(result).to be_a(HealthChecks::Result)
      expect(result.findings).to be_an(Array)
    end
  end

  it "emits a structured completion log with findings count and duration" do
    allow(HealthChecks::Cache).to receive(:write)
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

  it "discards silently when the project no longer exists" do
    allow(HealthChecks::Cache).to receive(:write)

    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(HealthChecks::Cache).not_to have_received(:write)
  end
end
