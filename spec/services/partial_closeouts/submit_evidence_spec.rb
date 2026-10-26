# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }
  let(:actor) { create(:user, account: project.account) }
  let!(:notification) do
    create(:notification, :error, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [ { "id" => "77:0", "criterion" => "Pilot", "next_step" => "Run pilot", "status" => "pending" } ] })
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records actor provenance and releases only the submitted occurrence after semantic validation" do
    allow(AgentHarness).to receive(:send_message).and_return(double(success?: true,
      output: '{"status":"sufficient","reason":"The report documents the required pilot."}'))

    result = described_class.call(issue:, actor:, prerequisite_id: "77:0", evidence_type: "report",
      reference: "https://example.test/report", explanation: "The report contains the approved pilot result.")

    expect(result).to be_success
    prerequisite = notification.reload.metadata.fetch("prerequisites").first
    expect(prerequisite).to include("status" => "sufficient")
    expect(prerequisite.fetch("evidence")).to include("actor_id" => actor.id, "type" => "report")
  end
end
