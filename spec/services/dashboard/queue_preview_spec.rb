# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueuePreview do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

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

    it "refreshes the cached snapshot after the dashboard version changes" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")

      create(:agent_run, :queued, :manual, project:, created_at: 2.minutes.ago)
      first = described_class.call(user:)

      create(:agent_run, :queued, :manual, project:, created_at: 1.minute.ago)
      cached = described_class.call(user:)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
      refreshed = described_class.call(user:)

      expect(first.size).to eq(1)
      expect(cached.size).to eq(1)
      expect(refreshed.size).to eq(2)
    end
  end
end
