# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueuePreview do
  describe ".call" do
    it "assigns sequential positions from the visible snapshot order" do
      account = create(:account)
      user = create(:user, account: account)
      first_project = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")
      second_project = create(:project, account: account, created_by: user, owner: "octo", repo: "beta")

      create(:agent_run, :queued, :manual, project: first_project, created_at: 3.minutes.ago)
      create(:agent_run, :queued, :manual, project: second_project, created_at: 2.minutes.ago)

      preview = described_class.call(user:)

      expect(preview.map(&:position)).to eq([ 1, 2 ])
      expect(preview.map { |entry| entry.run.project.full_name }).to eq([ "octo/alpha", "octo/beta" ])
    end

    it "reports waiting for capacity when the owner is at max_concurrent_runs" do
      account = create(:account)
      user = create(:user, account: account)
      user.settings.update!(max_concurrent_runs: 1)
      project = create(:project, account: account, created_by: user)

      create(:agent_run, :running, project:)
      create(:agent_run, :queued, :manual, project:)

      preview = described_class.call(user:)

      expect(preview.sole.waiting_reason).to eq("Waiting for capacity")
    end

    it "reports waiting for project slot for same-owner same-tier work behind another queued run" do
      account = create(:account)
      user = create(:user, account: account)
      user.settings.update!(fair_queue_across_projects: true, max_concurrent_runs: 3)
      first_project = create(:project, account: account, created_by: user)
      second_project = create(:project, account: account, created_by: user)

      create(:agent_run, :queued, :manual, project: first_project, created_at: 2.minutes.ago)
      second_run = create(:agent_run, :queued, :manual, project: second_project, created_at: 1.minute.ago)

      preview = described_class.call(user:)
      second_entry = preview.find { |entry| entry.run.id == second_run.id }

      expect(second_entry.waiting_reason).to eq("Waiting for project slot")
    end

    it "keeps reporting capacity when earlier same-owner runs already consume the remaining slots" do
      account = create(:account)
      user = create(:user, account: account)
      user.settings.update!(fair_queue_across_projects: true, max_concurrent_runs: 1)
      first_project = create(:project, account: account, created_by: user)
      second_project = create(:project, account: account, created_by: user)

      create(:agent_run, :queued, :manual, project: first_project, created_at: 2.minutes.ago)
      second_run = create(:agent_run, :queued, :manual, project: second_project, created_at: 1.minute.ago)

      preview = described_class.call(user:)
      second_entry = preview.find { |entry| entry.run.id == second_run.id }

      expect(second_entry.waiting_reason).to eq("Waiting for capacity")
    end

    it "reports lower priority when a higher-tier run is ahead in the queue" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)
      high_issue = create(:issue, project:, labels: [ "P1" ])

      create(:agent_run, :queued, :automatic, project:, issue: high_issue, created_at: 2.minutes.ago)
      lower_run = create(:agent_run, :queued, :automatic, :with_custom_prompt, project:, created_at: 1.minute.ago)

      preview = described_class.call(user:)
      lower_entry = preview.find { |entry| entry.run.id == lower_run.id }

      expect(lower_entry.waiting_reason).to eq("Lower priority")
    end

    it "reports budget exceeded when the project's hard-stop budget is already exhausted" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)
      create(:cost_budget, :hard_stop, :daily, project:, limit_cents: 100, current_usage_cents: 100)
      run = create(:agent_run, :queued, :manual, project:)

      expect(CostBudgets::Check).not_to receive(:call)

      preview = described_class.call(user:)
      entry = preview.find { |item| item.run.id == run.id }

      expect(entry.waiting_reason).to eq("Budget exceeded")
    end

    it "includes orphaned projects for the account fallback owner" do
      account = create(:account)
      fallback_owner = create(:user, account: account)
      orphaned_project = create(:project, account: account, created_by: nil, owner: "octo", repo: "orphaned")

      create(:agent_run, :queued, :manual, project: orphaned_project)

      preview = described_class.call(user: fallback_owner)

      expect(preview.map { |entry| entry.run.project_id }).to eq([ orphaned_project.id ])
    end

    it "preloads source pull request issues for visible runs" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)
      pull_request = create(:issue, project:, github_number: 42, is_pull_request: true, labels: [ "P1" ])

      create(:agent_run, :queued, project:, trigger_type: "automatic", source_pull_request_number: pull_request.github_number)

      preview = described_class.call(user:)
      run = preview.sole.run

      expect(run.instance_variable_defined?(:@source_pull_request_record)).to be(true)
      expect(run.source_pull_request_record).to eq(pull_request)
    end
  end
end
