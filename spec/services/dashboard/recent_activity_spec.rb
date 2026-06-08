# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::RecentActivity do
  def create_activity_items(project:, timestamp:)
    [
      create(:agent_run, project: project, status: "completed", completed_at: timestamp),
      create(:agent_run, project: project, status: "completed", completed_at: nil, created_at: timestamp),
      create(:issue, :pull_request, project: project, pr_review_phase: "merged", github_updated_at: timestamp),
      create(:quality_pause_event, :paused, project: project, created_at: timestamp)
    ]
  end

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "returns finished agent runs, merged PRs, and quality pause events for the account, sorted by recency" do
      older_run = create(:agent_run, project: project, status: "completed",
                                     completed_at: 2.hours.ago,
                                     duration_seconds: 30)
      newer_run = create(:agent_run, project: project, status: "completed",
                                     completed_at: 5.minutes.ago,
                                     duration_seconds: 10)
      merged_pr = create(:issue, :pull_request, project: project,
                                                pr_review_phase: "merged",
                                                github_updated_at: 30.minutes.ago)
      pause_event = create(:quality_pause_event, :paused, project: project, created_at: 10.minutes.ago)
      resume_event = create(:quality_pause_event, :resumed, project: project, created_at: 45.minutes.ago)

      items = described_class.call(account: account)

      expect(items).to eq([ newer_run, pause_event, merged_pr, resume_event, older_run ])
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
      create(:quality_pause_event, :paused, project: other_project, created_at: 1.minute.ago)

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

    it "excludes stale activity outside the recent window" do
      stale_items = create_activity_items(project:, timestamp: 15.days.ago)
      fresh_items = create_activity_items(project:, timestamp: 1.hour.ago)

      items = described_class.call(account: account)

      expect(items).to match_array(fresh_items)
      expect(items).not_to include(*stale_items)
    end

    it "refreshes the cached activity feed after the dashboard version changes" do
      create(:agent_run, project: project, status: "completed", completed_at: 2.minutes.ago, duration_seconds: 30)
      first = described_class.call(account: account)

      create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 30)
      cached = described_class.call(account: account)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
      refreshed = described_class.call(account: account)

      expect(first.size).to eq(1)
      expect(cached.size).to eq(1)
      expect(refreshed.size).to eq(2)
    end
  end
end
