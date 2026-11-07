# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-006
# @spec POST-DEPLOY-008
RSpec.describe PostDeployMeasurements::ReconcileResult do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:notification) do
    create(:notification, account: account, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      subject: issue, severity: :error, blocking: true,
      metadata: { "prerequisites" => [ bound_occurrence, other_occurrence ] })
  end
  # The live occurrence revision the notification recorded at publish time;
  # the release path must treat any other recorded revision as moved.
  let(:recorded_revision) { PartialCloseouts::Assessment.source_revision_for(issue) }
  let(:bound_occurrence) do
    { "identity" => "identity-a", "criterion" => "Record the live post-deploy count",
      "kind" => "human", "source_revision" => recorded_revision, "source_issue_number" => issue.github_number }
  end
  let(:other_occurrence) do
    { "identity" => "identity-b", "criterion" => "An unrelated human decision",
      "kind" => "human", "source_revision" => recorded_revision, "source_issue_number" => issue.github_number }
  end
  let(:measurement) do
    create(:post_deploy_measurement, issue: issue, project: project, status: "passed",
      prerequisite_identity: "identity-a", deployed_revision: "pr-7@2026-11-07T00:00:00Z",
      counts: { "actionable_closed_source" => 0 },
      details: { "comparison" => { "baseline" => 36, "target" => 0 } })
  end

  # The prerequisite notification must exist before reconciliation runs.
  before { notification }

  it "records machine evidence for exactly the bound occurrence and keeps the notification open" do
    notification
    result = described_class.call(measurement.reload)

    expect(result.released).to be(false)
    expect(notification.reload).to be_active
    submission = notification.reload.metadata["evidence_submissions"].sole
    expect(submission).to include(
      "prerequisite_identity" => "identity-a",
      "outcome" => "sufficient",
      "post_deploy_measurement_id" => measurement.id,
      "source_revision" => recorded_revision
    )
    expect(submission["explanation"]).to include("planning_hold_notifications_actionable")
  end

  it "releases only when every occurrence is satisfied, never whole-issue completion" do
    notification.update!(metadata: notification.metadata.merge(
      "prerequisites" => [ bound_occurrence ],
      "evidence_submissions" => [
        { "prerequisite_identity" => "identity-b", "evidence_url" => "https://example.test",
          "explanation" => "human", "outcome" => "sufficient", "source_revision" => recorded_revision,
          "validated_at" => Time.current.iso8601 }
      ]))

    expect(Dashboard::CacheVersion).to receive(:bump).with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      .at_least(:once)

    result = described_class.call(measurement.reload)

    expect(result.released).to be(true)
    resolved = notification.reload
    expect(resolved.resolved_at).to be_present
    expect(resolved.metadata["released_by"]).to eq("post_deploy_measurement")
    expect(measurement.reload).to be_released
  end

  it "keeps a superseded occurrence gated when its source revision moved" do
    notification.update!(metadata: notification.metadata.merge(
      "prerequisites" => [ bound_occurrence.merge("source_revision" => "rev-moved") ]))

    result = described_class.call(measurement.reload)

    expect(result.released).to be(false)
    expect(notification.reload).to be_active
    submission = notification.reload.metadata["evidence_submissions"].sole
    expect(submission["outcome"]).to eq("stale")
  end

  it "is idempotent under duplicate release events" do
    notification.update!(metadata: notification.metadata.merge(
      "prerequisites" => [ bound_occurrence ]))

    first = described_class.call(measurement.reload)
    second = described_class.call(measurement.reload)

    expect(first.released).to be(true)
    expect(second.reason).to eq("prerequisite was already released")
    expect(notification.reload.metadata["evidence_submissions"].length).to eq(1)
  end

  it "does nothing without a bound prerequisite identity" do
    measurement.update!(prerequisite_identity: nil)

    result = described_class.call(measurement.reload)

    expect(result.released).to be(false)
    expect(result.reason).to eq("measurement is not bound to a prerequisite")
  end

  it "does nothing when the notification is gone or the occurrence dropped" do
    notification.update!(resolved_at: Time.current)

    result = described_class.call(measurement.reload)

    expect(result.released).to be(false)
    expect(result.reason).to eq("no active prerequisite notification for this issue")
  end

  it "does nothing for a measurement that did not pass" do
    notification
    measurement.update!(status: "failed")

    result = described_class.call(measurement.reload)

    expect(result.released).to be(false)
    expect(notification.reload).to be_active
    expect(notification.reload.metadata["evidence_submissions"]).to be_nil
  end
end
