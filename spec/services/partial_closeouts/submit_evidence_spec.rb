# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-030
RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }
  let(:actor) { create(:user, account: project.account) }
  let(:notification) do
    create(:notification, :error, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: { "prerequisites" => [ prerequisite ] })
  end
  let(:prerequisite) do
    { "id" => "12:0", "criterion" => "pilot sign-off", "explanation" => "Attach the signed pilot decision.",
      "source_revision" => "source-a", "intent_revision" => "intent-a" }
  end

  it "records insufficient evidence without releasing the scheduling blocker" do
    assessor = ->(**) { { "outcome" => "insufficient", "reasoning" => "The linked run has no pilot decision.", "next_action" => "Attach the signed decision." } }

    result = described_class.call(notification:, actor:, prerequisite_id: "12:0", evidence_type: "link",
      reference: "https://example.test/pilot", explanation: "Pilot result", source_revision: "source-a", assessor:)

    expect(result.outcome).to eq("insufficient")
    expect(notification.reload).to be_active
    expect(notification.metadata.dig("evidence_submissions", "12:0", "outcome")).to eq("insufficient")
  end

  it "releases only after every current prerequisite is sufficient" do
    notification.update!(metadata: { "prerequisites" => [ prerequisite, prerequisite.merge("id" => "12:1") ] })
    assessor = ->(**) { { "outcome" => "sufficient", "reasoning" => "The evidence directly satisfies the criterion.", "next_action" => "Continue." } }

    described_class.call(notification:, actor:, prerequisite_id: "12:0", evidence_type: "report", reference: "report:1", explanation: "Signed decision", source_revision: "source-a", assessor:)
    expect(notification.reload).to be_active

    described_class.call(notification:, actor:, prerequisite_id: "12:1", evidence_type: "report", reference: "report:2", explanation: "Independent result", source_revision: "source-a", assessor:)
    expect(notification.reload.resolved_at).to be_present
  end

  it "marks a changed evidence generation stale rather than resolving it" do
    assessor = ->(**) { { "outcome" => "sufficient", "reasoning" => "old", "next_action" => "Continue." } }

    result = described_class.call(notification:, actor:, prerequisite_id: "12:0", evidence_type: "link",
      reference: "https://example.test/pilot", explanation: "Pilot result", source_revision: "changed", assessor:)

    expect(result.outcome).to eq("stale")
    expect(notification.reload).to be_active
  end
end
