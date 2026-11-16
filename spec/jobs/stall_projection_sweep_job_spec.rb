# frozen_string_literal: true

require "rails_helper"

RSpec.describe StallProjectionSweepJob do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:flag) { Issues::StalledCloseoutProjection::FLAG }

  def create_stalled_issue(github_number:, merged_pr_number: 14)
    issue = create(:issue, project: project, github_number: github_number, paid_state: "in_progress")
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: merged_pr_number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
    issue
  end

  describe "#perform" do
    it "schedules a recomputation for an enrolled project whose inputs changed" do
      issue = create_stalled_issue(github_number: 41)
      FeatureFlags.enable!(flag, project: project)
      Issues::StalledCloseoutProjection.recompute(project)
      create(:agent_run, :queued, project: project, issue: issue)

      expect { described_class.perform_now }.to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }.by(1)
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(enqueued[:job]).to eq(RecomputeStallProjectionJob)
      expect(enqueued[:args]).to eq([project.id])
    end

    it "keeps an enrolled project with a current checkpoint out of the sweep" do
      create_stalled_issue(github_number: 42)
      FeatureFlags.enable!(flag, project: project)
      Issues::StalledCloseoutProjection.recompute(project)

      expect { described_class.perform_now }.not_to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
    end

    it "always schedules a project whose initial recomputation has not succeeded yet" do
      create_stalled_issue(github_number: 43)
      FeatureFlags.enable!(flag, project: project)

      expect { described_class.perform_now }.to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }.by(1)
    end

    it "ignores projects the rollout guard has not enrolled" do
      create_stalled_issue(github_number: 44)

      expect { described_class.perform_now }.not_to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }
    end
  end
end

RSpec.describe RecomputeStallProjectionJob do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true,
      auto_merge_mode: "all", owner_reviewer_login: "viamin", owner: "acme", repo: "alpha")
  end

  it "recomputes the project's projection under its own tenant context" do
    issue = create(:issue, project: project, github_number: 51, paid_state: "in_progress")
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: 52,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
    FeatureFlags.enable!(Issues::StalledCloseoutProjection::FLAG, project: project)

    described_class.perform_now(project.id)

    expect(StallProjectionStall.where(project: project).map(&:issue_id)).to eq([issue.id])
    expect(StallProjectionCheckpoint.find_by(project: project)).to be_evaluated
  end
end
