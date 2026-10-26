# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-031
RSpec.describe PartialCloseouts::ResolveEvidence do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: actor) }
  let(:issue) { create(:issue, project: project) }
  let(:notification) do
    create(:notification, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, severity: :error, blocking: true,
      metadata: { "prerequisites" => [ { "criterion" => "pilot", "next_step" => "Run the pilot.", "status" => "awaiting_evidence", "outcome" => "pending_validation" } ] })
  end

  before do
    PartialCloseouts::SubmitEvidence.call(notification:, actor:, criterion: "pilot", kind: "durable_artifact",
      reference: "https://example.test/pilot", revision: "report-v1", explanation: "The signed pilot report addresses this criterion.")
  end

  it "records sufficient evidence and resolves only when every prerequisite is satisfied" do
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true, output: '{"outcome":"sufficient","reasoning":"The signed report covers the requested pilot."}'))

    result = described_class.call(notification:, criterion: "pilot")

    expect(result).to be_success
    prerequisite = notification.reload.metadata.fetch("prerequisites").first
    expect(prerequisite).to include("status" => "satisfied", "outcome" => "sufficient")
    expect(notification).not_to be_active
  end

  it "keeps insufficient evidence blocking with a retry action" do
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true, output: '{"outcome":"insufficient","reasoning":"The report does not identify the required environment."}'))

    result = described_class.call(notification:, criterion: "pilot")

    expect(result).to be_success
    prerequisite = notification.reload.metadata.fetch("prerequisites").first
    expect(prerequisite).to include("outcome" => "insufficient", "status" => "awaiting_evidence")
    expect(prerequisite.fetch("next_action")).to include("Submit")
    expect(notification).to be_active
  end

  it "rejects a delayed assessment after the prerequisite changes" do
    prerequisite = notification.metadata.fetch("prerequisites").first.merge("next_step" => "Run the revised pilot.")
    notification.update!(metadata: notification.metadata.merge("prerequisites" => [ prerequisite ]))

    result = described_class.call(notification:, criterion: "pilot")

    expect(result.outcome).to eq("stale")
    expect(notification.reload.metadata.dig("prerequisites", 0, "outcome")).to eq("stale")
  end

  it "records unavailable semantic assessment without releasing scheduling" do
    allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "provider unavailable")

    result = described_class.call(notification:, criterion: "pilot")

    expect(result.outcome).to eq("unavailable")
    expect(notification.reload).to be_active
  end
end
