# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:actor) { create(:user, account: project.account) }
  let(:identity) { "occurrence-1" }
  let(:notification) do
    create(:notification, account: project.account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error, blocking: true, metadata: { "prerequisites" => [ { "identity" => identity } ] })
  end

  it "records external evidence as pending validation without releasing the prerequisite" do # @spec PARTIAL-CLOSEOUT-032
    result = described_class.call(notification:, actor:, prerequisite_identity: identity,
      evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")

    expect(result.outcome).to eq("pending_validation")
    expect(notification.reload).to be_active
    expect(notification.metadata.fetch("evidence_submissions").last).to include("actor_id" => actor.id,
      "prerequisite_identity" => identity, "outcome" => "pending_validation")
  end

  it "rejects evidence for a different prerequisite occurrence" do # @spec PARTIAL-CLOSEOUT-032
    expect {
      described_class.call(notification:, actor:, prerequisite_identity: "other",
        evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")
    }.to raise_error(ArgumentError, "prerequisite occurrence is no longer current")
  end

  it "marks evidence stale when the prerequisite source revision changed" do # @spec PARTIAL-CLOSEOUT-032
    notification.update!(metadata: { "prerequisites" => [ { "identity" => identity, "source_revision" => "old" } ] })

    result = described_class.call(notification:, actor:, prerequisite_identity: identity,
      evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")

    expect(result.outcome).to eq("stale")
    expect(notification.reload).to be_active
  end
end
