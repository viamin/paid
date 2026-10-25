# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitPrerequisiteEvidence do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, github_state: "open") }
  let(:actor) { create(:user, account: account) }
  let(:source_revision) { Issues::CloseoutEvidence.call(issue).digest }
  let(:intent_revision) { PartialCloseouts::Assessment.intent_revision_for(issue) }
  let(:notification) do
    create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "source_revision" => source_revision, "intent_revision" => intent_revision,
                  "prerequisites" => [ { "id" => "42:0", "criterion" => "Pilot", "requirement" => "Attach results" } ] })
  end

  it "records revision-bound provenance as pending validation without resolving the prerequisite" do # @spec PARTIAL-CLOSEOUT-030
    result = described_class.call(notification: notification, actor: actor, prerequisite_id: "42:0",
      evidence_type: "url", reference: "https://example.test/pilot", explanation: "This is the measured pilot result.")

    expect(result).to be_success
    expect(result.status).to eq("pending_validation")
    submission = notification.reload.metadata.fetch("evidence_submissions").sole
    expect(submission).to include("prerequisite_id" => "42:0", "actor_id" => actor.id,
      "source_revision" => source_revision, "intent_revision" => intent_revision, "outcome" => "pending_validation")
    expect(notification.resolved_at).to be_nil
  end

  it "rejects a stale evidence generation" do # @spec PARTIAL-CLOSEOUT-030
    notification.update!(metadata: notification.metadata.merge("source_revision" => "stale"))

    result = described_class.call(notification: notification, actor: actor, prerequisite_id: "42:0",
      evidence_type: "url", reference: "https://example.test/pilot", explanation: "This is the measured pilot result.")

    expect(result).not_to be_success
    expect(result.error).to include("changed")
    expect(notification.reload.metadata).not_to have_key("evidence_submissions")
  end
end
