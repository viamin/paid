# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::RecentActivity do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "returns finished agent runs and merged PRs for the account, sorted by recency" do
      older_run = create(:agent_run, project: project, status: "completed",
                                     completed_at: 2.hours.ago,
                                     duration_seconds: 30)
      newer_run = create(:agent_run, project: project, status: "completed",
                                     completed_at: 5.minutes.ago,
                                     duration_seconds: 10)
      merged_pr = create(:issue, :pull_request, project: project,
                                                pr_review_phase: "merged",
                                                github_updated_at: 30.minutes.ago)

      items = described_class.call(account: account)

      expect(items).to eq([ newer_run, merged_pr, older_run ])
    end

    it "excludes agent runs that are not finished" do
      create(:agent_run, project: project, status: "running", started_at: 1.minute.ago)

      expect(described_class.call(account: account)).to be_empty
    end

    it "excludes PRs that have not been merged" do
      create(:issue, :pull_request, project: project, pr_review_phase: "ready",
                                    github_updated_at: 1.minute.ago)

      expect(described_class.call(account: account)).to be_empty
    end

    it "excludes non-PR issues even if somehow marked as merged" do
      create(:issue, project: project, is_pull_request: false,
                     github_updated_at: 1.minute.ago)

      expect(described_class.call(account: account)).to be_empty
    end

    it "scopes results to the given account" do
      other_project = create(:project)
      create(:agent_run, project: other_project, status: "completed", completed_at: 1.minute.ago)
      create(:issue, :pull_request, project: other_project, pr_review_phase: "merged",
                                    github_updated_at: 1.minute.ago)

      expect(described_class.call(account: account)).to be_empty
    end

    it "caps the combined result at the configured limit" do
      12.times do |i|
        create(:agent_run, project: project, status: "completed",
                           completed_at: (i + 1).minutes.ago)
      end
      12.times do |i|
        create(:issue, :pull_request, project: project, pr_review_phase: "merged",
                                      github_updated_at: (i + 1).minutes.ago)
      end

      expect(described_class.call(account: account, limit: 5).size).to eq(5)
      expect(described_class.call(account: account).size).to eq(described_class::DEFAULT_LIMIT)
    end
  end
end
