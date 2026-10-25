# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitPrerequisiteEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:actor) { create(:user, account: project.account) }
  let!(:notification) do
    create(:notification, account: project.account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error, blocking: true, metadata: {
        "prerequisites" => [ { "criterion" => "Production p95", "source_revision" => Issues::CloseoutEvidence.call(issue).digest,
          "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue) } ]
      })
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records revision-bound candidate evidence without treating a URL as acceptance" do
    result = described_class.call(issue:, actor:, criterion_index: 0, evidence_type: "url",
      reference: "https://example.test/evidence", revision: "run-17", explanation: "Production measurement artifact")

    expect(result).to be_success
    submission = notification.reload.metadata.fetch("evidence_submissions").sole
    expect(submission).to include("outcome" => "pending_validation", "actor_id" => actor.id, "criterion_index" => 0)
  end
end
