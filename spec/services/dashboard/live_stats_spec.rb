# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::LiveStats do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account, active: true) }

    around do |example|
      freeze_time { example.run }
    end

    it "returns live dashboard counts for the account" do
      create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago, container_id: "container-1")
      create(:agent_run, project: project, status: "pending")
      create(:agent_run, project: project, status: "queued")
      create(:agent_run, project: project, status: "completed", completed_at: 2.hours.ago)
      create(:agent_run, project: project, status: "failed", completed_at: 1.hour.ago)

      stats = described_class.call(account: account)

      expect(stats).to include(
        active_runs: 2,
        queued_runs: 1,
        completed_today: 1,
        failed_today: 1,
        active_containers: 1,
        total_projects: 1,
        active_projects: 1
      )
    end
  end
end
