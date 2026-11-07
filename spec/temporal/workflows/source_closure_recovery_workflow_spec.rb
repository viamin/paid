# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::SourceClosureRecoveryWorkflow do
  let(:workflow) { described_class.new }
  let(:input) { { agent_run_id: 42, project_id: 7, recovery_attempt: 1, goal: "create_feature" } }
  let(:post_closeout_activities) do
    [
      Activities::ReconcilePartialCloseoutActivity,
      Activities::AdvancePartialCloseoutActivity,
      Activities::UpdateIssueWithPrActivity,
      Activities::RequestReviewActivity,
      Activities::CaptureScreenshotsActivity,
      Activities::DraftDecisionRecordActivity,
      Activities::ChainLidPlanningActivity
    ]
  end

  before do
    allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
    allow(Temporalio::Workflow).to receive(:patched).with("source-closure-recovery-post-pr-v1").and_return(true)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "continues through issue reconciliation and review publication after creating the PR" do
    calls = []
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      calls << activity
      case activity.name
      when "Activities::CreatePullRequestActivity"
        { pull_request_url: "https://github.com/o/r/pull/9", pull_request_number: 9 }
      when "Activities::ReconcilePartialCloseoutActivity"
        { gaps_remain: false }
      else
        {}
      end
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect(workflow.execute(input)).to include(recovered: true)
    expect(calls).to include(*post_closeout_activities)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "propagates failures outside assessment instead of parking them" do
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      raise "provision failed" if activity == Activities::ProvisionContainerActivity
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect { workflow.execute(input) }.to raise_error("provision failed")
    expect(workflow).not_to have_received(:run_activity).with(Activities::ParkSourceClosureRecoveryActivity, any_args)
    expect(workflow).to have_received(:run_cleanup_activity).with(
      Activities::ReleaseSourceClosureRecoveryClaimActivity,
      { agent_run_id: 42, recovery_attempt: 1 }, timeout: 30
    )
  end
end
