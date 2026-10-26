# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:actor) { create(:user, account: project.account) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:notification) do
    create(:notification, :error, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      description: "Pilot evidence: upload the signed result.")
  end

  # @spec PARTIAL-CLOSEOUT-028
  it "records provenance as pending validation without releasing the prerequisite" do
    result = described_class.call(notification:, actor:, kind: "report",
      reference: "https://example.test/report/7", explanation: "Signed pilot report.",
      revisions: { "source" => "abc" })

    expect(result).to be_success
    expect(notification.reload).to be_active
    expect(notification.metadata.fetch("evidence_submissions").first).to include(
      "outcome" => "pending_validation", "actor_id" => actor.id,
      "reference" => "https://example.test/report/7", "revisions" => { "source" => "abc" }
    )
  end

  it "rejects a bare link or unsupported evidence type" do
    result = described_class.call(notification:, actor:, kind: "comment",
      reference: "https://example.test/comment/7", explanation: "")

    expect(result).not_to be_success
    expect(notification.reload.metadata).to eq({})
  end
end
