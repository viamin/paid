# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::LiveStats do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account, active: true) }

    around do |example|
      travel_to(Time.current.beginning_of_day + 12.hours) { example.run }
    end

    it "returns live dashboard counts for the account" do
      create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago, container_id: "container-1")
      create(:agent_run, project: project, status: "running", started_at: 3.minutes.ago)
      create(:agent_run, project: project, status: "queued")
      create(:agent_run, project: project, status: "queued", temporal_workflow_id: "wf-123")
      create(:agent_run, project: project, status: "completed", completed_at: 2.hours.ago)
      create(:agent_run, project: project, status: "failed", completed_at: 1.hour.ago)

      stats = described_class.call(account: account)

      expect(stats).to include(
        active_runs: 2,
        queued_runs: 1,
        completed_today: 1,
        failed_today: 1
      )
    end

    # @spec LIVE-PREVIEW-003
    it "excludes synthetic operational runs from live dashboard counts" do
      create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
      create(:agent_run, :running, :synthetic, project: project, started_at: 3.minutes.ago)
      create(:agent_run, :synthetic, project: project, status: "completed", completed_at: 1.hour.ago)

      stats = described_class.call(account: account)

      expect(stats[:active_runs]).to eq(1)
      expect(stats[:completed_today]).to eq(0)
    end

    it "excludes preview provisioning runs from the active create_pr metric" do
      create(:agent_run, :running, project: project, goal: "create_pr", started_at: 5.minutes.ago)
      create(
        :agent_run,
        :running,
        :internal_agent,
        project: project,
        goal: "create_pr",
        started_at: 4.minutes.ago,
        synthetic: true,
        external_metadata: { "preview_session" => true }
      )

      stats = described_class.call(account: account)

      expect(stats[:active_create_pr_runs]).to eq(1)
    end

    it "caches the aggregated payload" do
      create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)

      first = described_class.call(account: account)
      create(:agent_run, project: project, status: "running", started_at: 1.minute.ago)

      cached = described_class.call(account: account)
      Rails.cache.clear
      refreshed = described_class.call(account: account)

      expect(first[:active_runs]).to eq(1)
      expect(cached[:active_runs]).to eq(1)
      expect(refreshed[:active_runs]).to eq(2)
    end
  end
end
