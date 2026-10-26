# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-030
RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: actor) }
  let(:issue) { create(:issue, project: project) }
  let(:notification) do
    create(:notification, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, severity: :error, blocking: true,
      metadata: { "prerequisites" => [ { "criterion" => "pilot", "status" => "awaiting_evidence" } ] })
  end

  it "records exact submitted evidence as pending validation without releasing scheduling" do
    result = described_class.call(notification: notification, actor: actor, criterion: "pilot", kind: "durable_artifact",
      reference: "https://example.test/report", revision: "sha-123", explanation: "The approved pilot report covers the rollout criterion.")

    expect(result).to be_success
    evidence = notification.reload.metadata.dig("prerequisites", 0, "evidence")
    expect(notification).to be_active
    expect(notification.metadata.dig("prerequisites", 0, "outcome")).to eq("pending_validation")
    expect(evidence).to include("reference" => "https://example.test/report", "revision" => "sha-123", "actor_id" => actor.id)
    expect(evidence.fetch("prerequisite_revision")).to be_present
  end

  it "refuses a bare link without provenance and explanation" do
    result = described_class.call(notification: notification, actor: actor, criterion: "pilot", kind: "link",
      reference: "https://example.test/report", revision: "", explanation: "")

    expect(result).not_to be_success
    expect(notification.reload.metadata.dig("prerequisites", 0, "status")).to eq("awaiting_evidence")
  end
end
