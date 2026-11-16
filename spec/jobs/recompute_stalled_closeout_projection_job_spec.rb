# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecomputeStalledCloseoutProjectionJob do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) do
    create(:project, account: account, created_by: owner, auto_pick_enabled: true, owner: "acme", repo: "alpha")
  end
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  def seed_stall
    create(
      :issue, :pull_request, project: project, github_number: 12, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id
    )
  end

  it "recomputes the projection for a rollout-enabled project outside rendering" do
    seed_stall
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project:)

    described_class.perform_now(project.id)

    check = StalledCloseoutProjectionCheck.find_by!(project: project)
    expect(check.computed_at).to be_present
    expect(StalledCloseoutProjectionRow.where(project: project).map(&:issue_id)).to contain_exactly(issue.id)
  end

  it "is a no-op while the rollout guard is disabled" do
    seed_stall

    described_class.perform_now(project.id)

    expect(StalledCloseoutProjectionCheck.where(project: project)).to be_empty
  end

  it "discards a missing project without retrying" do
    expect { described_class.perform_now(project.id + 1) }.not_to raise_error
  end
end
