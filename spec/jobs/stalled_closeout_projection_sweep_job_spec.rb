# frozen_string_literal: true

require "rails_helper"

RSpec.describe StalledCloseoutProjectionSweepJob do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) do
    create(:project, account: account, created_by: owner, auto_pick_enabled: true, owner: "acme", repo: "alpha")
  end

  def seed_stall(parent)
    create(
      :issue, :pull_request, project: parent.project, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: parent.id
    )
  end

  it "schedules recomputation for enabled projects with changed admission inputs" do
    issue = create(:issue, project: project, github_state: "open", paid_state: "in_progress")
    seed_stall(issue)
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.recompute(project)
    expect(Issues::StalledCloseoutProjection.due?(project.reload)).to be(false)

    create(:agent_run, project: project, issue: issue, goal: "create_pr", status: "queued")

    expect { described_class.perform_now }
      .to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
  end

  it "schedules the initial recomputation for an enabled project without a checkpoint" do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)

    expect { described_class.perform_now }
      .to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
  end

  it "skips projects where the rollout guard is disabled" do
    create(:issue, project: project, github_state: "open", paid_state: "in_progress")

    expect { described_class.perform_now }.not_to have_enqueued_job
  end

  it "skips an enabled project whose inputs have not moved" do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)
    Issues::StalledCloseoutProjection.recompute(project)

    expect { described_class.perform_now }.not_to have_enqueued_job
  end
end
