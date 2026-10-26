# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:actor) { create(:user, account: project.account) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:criterion) { "macOS acceptance" }

  # @spec PARTIAL-CLOSEOUT-030
  it "records external evidence as pending validation without releasing the prerequisite" do
    notification = current_prerequisite_notification

    result = described_class.call(
      issue:, actor:, criterion:, evidence_kind: "durable_artifact",
      source_url: "https://evidence.example.test/pilot/42", explanation: "The signed pilot report covers the requested device run."
    )

    expect(result).to be_success
    expect(result.submission).to have_attributes(outcome: "pending_validation", notification: notification, actor: actor)
    expect(notification.reload).to be_active
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not present the solo evaluation report as sufficient acceptance evidence" do
    current_prerequisite_notification

    result = described_class.call(
      issue:, actor:, criterion:, evidence_kind: "shadow_evaluation_report",
      explanation: "The report completed the frozen corpus reviewer run."
    )

    expect(result).to be_success
    expect(result.submission).to have_attributes(outcome: "insufficient", validated_at: be_present)
    expect(result.submission.reason).to include("missing production measures")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "refuses a stale assessment instead of accepting evidence against changed intent" do
    current_prerequisite_notification
    issue.update!(title: "Changed acceptance intent")

    result = described_class.call(
      issue:, actor:, criterion:, evidence_kind: "link",
      source_url: "https://evidence.example.test/changed", explanation: "A changed artifact."
    )

    expect(result).not_to be_success
    expect(PartialCloseoutEvidenceSubmission.where(issue:)).to be_empty
  end

  def current_prerequisite_notification
    evidence = Issues::CloseoutEvidence.call(issue)
    assessment = {
      "gaps" => [], "criteria" => [ { "criterion" => criterion, "state" => "unmet", "prerequisite_kind" => "human", "prerequisite" => "Run the approved pilot." } ],
      "source_revision" => evidence.digest, "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "assessed_at" => Time.current.iso8601
    }
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => assessment })
    Notifications::Publish.call(
      account: project.account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error, blocking: true, title: "#{criterion} needs operator action",
      description: "#{criterion}: Run the approved pilot."
    )
  end
end
