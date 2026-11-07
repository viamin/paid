# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-CHECK-007 POST-DEPLOY-CHECK-008
RSpec.describe PostDeployChecks::FeedPrerequisiteEvidence do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:parent_issue) { create(:issue, project:) }
  let(:prerequisite_identity) { "closed-planning-hold-count" }
  let(:current_source_revision) { PartialCloseouts::Assessment.source_revision_for(parent_issue) }

  def notification_with_occurrences(*extra_occurrences)
    occurrence = { "identity" => prerequisite_identity, "criterion" => "The live closed-planning-hold count is zero.",
                   "kind" => "human", "source_revision" => current_source_revision }
    create(:notification, account:, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, subject: parent_issue,
      blocking: true, severity: :error, metadata: { "prerequisites" => [ occurrence, *extra_occurrences ] })
  end

  def succeeded_run(active_with_closed_source: 0)
    allow(PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount).to receive(:call).and_return(
      PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount::Result.new(
        scope: project.full_name, active_total: 5, active_with_closed_source:, baseline: 36, target: 0
      )
    )
    PostDeployChecks::Run.call(
      check_key: PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount::KEY,
      project:, deployed_revision: "rev-1"
    )
  end

  it "resolves the notification when the run meets target and it is the only occurrence" do
    notification = notification_with_occurrences
    run = succeeded_run(active_with_closed_source: 0)

    submission = described_class.call(run:, notification:, prerequisite_identity:)

    expect(submission["outcome"]).to eq("sufficient")
    notification.reload
    expect(notification.resolved_at).to be_present
    expect(notification.metadata["released_by"]).to eq("trusted_measurement")
  end

  it "records sufficient evidence but does not resolve when another occurrence is not yet sufficient" do
    notification = notification_with_occurrences({ "identity" => "other", "criterion" => "Something else.", "kind" => "human" })
    run = succeeded_run(active_with_closed_source: 0)

    submission = described_class.call(run:, notification:, prerequisite_identity:)

    expect(submission["outcome"]).to eq("sufficient")
    expect(notification.reload.resolved_at).to be_nil
  end

  it "records an insufficient submission without resolving when the target is not met" do
    notification = notification_with_occurrences
    run = succeeded_run(active_with_closed_source: 3)

    submission = described_class.call(run:, notification:, prerequisite_identity:)

    expect(submission["outcome"]).to eq("insufficient")
    expect(notification.reload.resolved_at).to be_nil
  end

  it "does nothing for a stale occurrence whose source revision no longer matches" do
    occurrence = { "identity" => prerequisite_identity, "criterion" => "Stale.", "kind" => "human", "source_revision" => "no-longer-current" }
    notification = create(:notification, account:, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      subject: parent_issue, blocking: true, severity: :error, metadata: { "prerequisites" => [ occurrence ] })
    run = succeeded_run

    submission = described_class.call(run:, notification:, prerequisite_identity:)

    expect(submission).to be_nil
    expect(notification.reload.metadata["evidence_submissions"]).to be_blank
  end

  it "returns nil and does nothing when the run has not succeeded" do
    notification = notification_with_occurrences
    run = PostDeployChecks::Run.call(
      check_key: PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount::KEY,
      project:, deployed_revision: nil
    )

    submission = described_class.call(run:, notification:, prerequisite_identity:)

    expect(submission).to be_nil
    expect(notification.reload.metadata["evidence_submissions"]).to be_blank
  end

  it "is idempotent: feeding the same already-fed run twice does not append a duplicate submission" do
    notification = notification_with_occurrences
    run = succeeded_run(active_with_closed_source: 0)

    described_class.call(run:, notification:, prerequisite_identity:)
    described_class.call(run:, notification:, prerequisite_identity:)

    expect(notification.reload.metadata["evidence_submissions"].size).to eq(1)
  end
end
