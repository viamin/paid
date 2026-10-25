# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ReconcilePrerequisiteEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:revisions) { { "source_revision" => Issues::CloseoutEvidence.call(issue).digest, "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue) } }

  # @spec PARTIAL-CLOSEOUT-031
  it "resolves only a sufficient occurrence and never relies on dismissal" do
    notification = create(:notification, account: project.account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error, blocking: true, metadata: {
        "prerequisites" => [ { "criterion" => "Production p95" } ],
        "evidence_submissions" => [ revisions.merge("criterion_index" => 0, "outcome" => "pending_validation", "prerequisite" => { "criterion" => "Production p95" }) ]
      })

    described_class.call(issue:, assessment: revisions.merge("criteria" => [ { "criterion" => "Production p95", "state" => "satisfied" } ]))

    expect(notification.reload.resolved_at).to be_present
    expect(notification.metadata.fetch("evidence_submissions").sole.fetch("outcome")).to eq("sufficient")
  end
end
