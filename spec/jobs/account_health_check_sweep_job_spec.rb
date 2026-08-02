# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccountHealthCheckSweepJob do
  let(:clean_result) do
    HealthChecks::Result.new(findings: [], checked_at: Time.current, duration_ms: 4)
  end

  let(:warning_result) do
    HealthChecks::Result.new(
      findings: [
        HealthChecks::Finding.new(check: "HealthChecks::Checks::Project::EmptyAllowlist",
                                  scope: :project, severity: :warning, message: "warn")
      ],
      checked_at: Time.current,
      duration_ms: 6
    )
  end

  describe "GoodJob concurrency" do
    it "runs on the maintenance queue with a single-flight concurrency key" do
      config = described_class.good_job_concurrency_config

      expect(described_class.queue_name).to eq("maintenance")
      expect(config[:total_limit]).to eq(1)
      expect(config[:enqueue_limit]).to eq(1)
      expect(config[:key]).to eq("account_health_sweep")
      expect(described_class.new.good_job_concurrency_key).to eq("account_health_sweep")
    end
  end

  describe "#perform" do
    before do
      allow(HealthChecks::Cache).to receive(:write)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
    end

    it "writes the cached result for each project and emits the sweep_completed log" do
      projects = create_list(:project, 2)
      allow(HealthChecks::Coordinator).to receive(:call).and_return(clean_result)

      described_class.perform_now

      projects.each do |project|
        expect(HealthChecks::Coordinator).to have_received(:call)
          .with(scope: :project, subject: project, include_network: true)
        expect(HealthChecks::Cache).to have_received(:write).with(project, clean_result)
      end
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "project_health.sweep_completed", projects_checked: 2, total_findings: 0)
      )
    end

    it "aggregates total findings across the project fleet" do
      create_list(:project, 2)
      results = [ warning_result, clean_result ].cycle
      allow(HealthChecks::Coordinator).to receive(:call) { results.next }

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(hash_including(projects_checked: 2, total_findings: 1))
    end

    it "runs each project under TenantContext system access (RLS bypass)" do
      create(:project)
      seen_bypass = nil
      allow(HealthChecks::Coordinator).to receive(:call) do
        seen_bypass = TenantContext.bypass_enabled?
        clean_result
      end

      described_class.perform_now

      expect(seen_bypass).to be(true)
    end

    it "isolates a failing project so the sweep continues and logs it" do
      good = create(:project)
      bad = create(:project, owner: "broken-owner", repo: "broken-repo")
      allow(HealthChecks::Coordinator).to receive(:call) do |subject:, **|
        raise "boom" if subject == bad

        clean_result
      end

      described_class.perform_now

      # The failing project is skipped; the healthy one is still cached.
      expect(HealthChecks::Cache).to have_received(:write).with(good, clean_result)
      expect(HealthChecks::Cache).not_to have_received(:write).with(bad, anything)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "project_health.sweep_project_failed", project_id: bad.id, error: "boom")
      )
      # Sweep still completes and reports the one project that succeeded.
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "project_health.sweep_completed", projects_checked: 1)
      )
    end
  end
end
