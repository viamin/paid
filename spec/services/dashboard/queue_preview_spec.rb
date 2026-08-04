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

    it "interleaves projects in dispatch order instead of clustering one project's backlog" do
      account = create(:account)
      user = create(:user, account: account)
      alpha = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")
      beta = create(:project, account: account, created_by: user, owner: "octo", repo: "beta")

      # Alpha has the larger backlog and older runs, so the raw QUEUE_ORDER
      # snapshot would place all three alpha runs ahead of beta. The
      # scheduler really round-robins by per-project in-flight count, so the
      # preview should interleave: alpha, beta, alpha, alpha.
      create(:agent_run, :queued, project: alpha, trigger_type: "automatic", created_at: 4.minutes.ago)
      create(:agent_run, :queued, project: alpha, trigger_type: "automatic", created_at: 3.minutes.ago)
      create(:agent_run, :queued, project: alpha, trigger_type: "automatic", created_at: 2.minutes.ago)
      create(:agent_run, :queued, project: beta, trigger_type: "automatic", created_at: 1.minute.ago)

      preview = described_class.call(user:)

      expect(preview.map { |entry| entry.run.project.repo }).to eq(%w[alpha beta alpha alpha])
    end

    it "surfaces a higher-priority run from a busy project across the round-robin" do
      account = create(:account)
      user = create(:user, account: account)
      alpha = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")
      beta = create(:project, account: account, created_by: user, owner: "octo", repo: "beta")

      # alpha is idle (0 in-flight); beta already has a run going, but its
      # queued run carries a P1 label. Once alpha claims one run both
      # projects tie at the same in-flight count, and beta's P1 run should
      # win the tie ahead of alpha's lower-priority backlog.
      create(:agent_run, :queued, project: alpha, trigger_type: "automatic", created_at: 2.minutes.ago)
      create(:agent_run, :queued, project: alpha, trigger_type: "automatic", created_at: 1.minute.ago)
      beta_issue = create(:issue, project: beta, labels: [ "P1" ])
      create(:agent_run, :queued, project: beta, issue: beta_issue, trigger_type: "automatic", created_at: 30.seconds.ago)
      create(:agent_run, :running, project: beta, started_at: 1.minute.ago)

      preview = described_class.call(user:)

      expect(preview.map { |entry| entry.run.project.repo }).to eq(%w[alpha beta alpha])
    end

    it "preserves per-project priority order within the round-robin" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")

      # A P3 run is older than a P1 run in the same project. The snapshot is
      # sorted by QUEUE_ORDER, so grouping must keep P1 ahead of P3 even
      # though the round-robin has a single project to draw from.
      create(:agent_run, :queued, project:, issue: create(:issue, project:, labels: [ "P3" ]),
               trigger_type: "automatic", created_at: 2.minutes.ago)
      create(:agent_run, :queued, project:, issue: create(:issue, project:, labels: [ "P1" ]),
               trigger_type: "automatic", created_at: 1.minute.ago)

      preview = described_class.call(user:)

      expect(preview.map { |entry| entry.run.queue_priority_tier }).to eq(%i[issue_p1 issue_p3])
    end

    it "matches strict-priority ordering without fair-share replay" do
      account = create(:account)
      account.tenant_setting!.update!(queue_fairness_mode: "strict_priority")
      user = create(:user, account: account)
      alpha = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")
      beta = create(:project, account: account, created_by: user, owner: "octo", repo: "beta")

      alpha_running_issue = create(:issue, project: alpha, labels: [ "P1" ])
      alpha_queued_issue = create(:issue, project: alpha, labels: [ "P1" ])
      beta_issue = create(:issue, project: beta, labels: [ "P2" ])
      create(:agent_run, :running, project: alpha, trigger_type: "automatic", issue: alpha_running_issue)
      create(:agent_run, :queued, project: alpha, trigger_type: "automatic", issue: alpha_queued_issue, created_at: 2.minutes.ago)
      create(:agent_run, :queued, project: beta, trigger_type: "automatic", issue: beta_issue, created_at: 1.minute.ago)

      preview = described_class.call(user:, queue_fairness_mode: "strict_priority")

      expect(preview.map { |entry| entry.run.project.repo }).to eq(%w[alpha beta])
    end

    it "uses the scheduler review tiebreak in strict-priority mode" do
      account = create(:account)
      account.tenant_setting!.update!(queue_fairness_mode: "strict_priority")
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user, owner: "octo", repo: "alpha")

      create_pr_run = create(:agent_run, :queued, :automatic, :existing_pr,
        project:, goal: "create_pr", source_pull_request_number: 42, created_at: 2.minutes.ago)
      review_run = create(:agent_run, :queued, :automatic, :review_goal,
        project:, source_pull_request_number: 43, created_at: 1.minute.ago)

      preview = described_class.call(user:, queue_fairness_mode: "strict_priority")

      expect(preview.map { |entry| entry.run.id }).to eq([ review_run.id, create_pr_run.id ])
    end

    it "does not promise every queued project is represented in the preview sample" do
      rendered = ApplicationController.render(
        partial: "dashboard/queue_preview",
        locals: { queue_preview: [], paused_projects: [], queue_fairness_mode: "fair_share" }
      )

      expect(rendered).to include("Balanced across sampled projects; priority ranks within each project.")
      expect(rendered).to include("approximate dispatch order from the next batch of queued work")
    end

    it "updates the preview copy for strict-priority accounts" do
      rendered = ApplicationController.render(
        partial: "dashboard/queue_preview",
        locals: { queue_preview: [], paused_projects: [], queue_fairness_mode: "strict_priority" }
      )

      expect(rendered).to include("Strict priority across the account; high-priority work can outrank other projects.")
      expect(rendered).to include("Strict priority lets queue priority outrank cross-project fairness")
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
