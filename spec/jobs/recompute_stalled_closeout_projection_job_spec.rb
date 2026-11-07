# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecomputeStalledCloseoutProjectionJob do # @spec PARTIAL-CLOSEOUT-042
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

  before { allow(Rails.logger).to receive(:info) }

  it "recomputes the project's projection and records the outcome" do
    issue = create(:issue, project: project, github_number: 41, paid_state: "in_progress")
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: 14,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )

    described_class.perform_now(project.id)

    checkpoint = PartialCloseoutStallCheckpoint.find_by!(project: project)
    expect(checkpoint).to be_successful
    expect(PartialCloseoutStall.find_by!(issue: issue)).to be_present
    expect(Rails.logger).to have_received(:info).with(
      hash_including(message: "issues.stall_projection_recomputed", project_id: project.id, stall_count: 1)
    )
  end

  it "discards a missing project instead of failing the queue" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "runs on maintenance with one in-flight recomputation per project" do
    config = described_class.good_job_concurrency_config

    expect(described_class.queue_name).to eq("maintenance")
    expect(config).to include(enqueue_limit: 1, perform_limit: 1)
    expect(described_class.new(project.id).instance_exec(&config[:key]))
      .to eq("recompute_stalled_closeout_projection/#{project.id}")
  end
end
