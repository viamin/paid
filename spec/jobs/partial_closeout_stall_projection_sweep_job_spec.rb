# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseoutStallProjectionSweepJob do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, active: true, auto_pick_enabled: true,
      owner: "acme", repo: "alpha")
  end
  let!(:unenrolled_project) do
    create(:project, account: account, created_by: user, active: true, auto_pick_enabled: true,
      owner: "acme", repo: "delta")
  end

  it "enqueues a recomputation for an enrolled project without a checkpoint" do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)

    expect { described_class.perform_now }
      .to enqueue_job(PartialCloseoutStallProjectionJob).with(project.id).at_least(:once)
  end

  it "enqueues a recomputation for an enrolled project whose inputs drifted" do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
    Issues::StalledCloseoutProjection.recompute!(project)

    create(:issue, project: project, github_state: "open", paid_state: "in_progress")

    expect { described_class.perform_now }
      .to enqueue_job(PartialCloseoutStallProjectionJob).with(project.id).at_least(:once)
  end

  it "skips enrolled projects whose checkpoint is current and projects that are not enrolled" do
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
    Issues::StalledCloseoutProjection.recompute!(project)
    create(:issue, project: unenrolled_project, github_state: "open", paid_state: "in_progress")

    expect { described_class.perform_now }
      .not_to have_enqueued_job(PartialCloseoutStallProjectionJob)
  end
end
