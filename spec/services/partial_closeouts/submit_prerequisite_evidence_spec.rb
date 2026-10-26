# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-030
RSpec.describe PartialCloseouts::SubmitPrerequisiteEvidence do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:) }
  let(:notification) do
    create(:notification, account:, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error, blocking: true, metadata: { "prerequisites" => prerequisites })
  end
  let(:prerequisites) do
    [
      { "id" => "11:0", "criterion" => "pilot", "source_revision" => "source-1", "intent_revision" => "intent-1" },
      { "id" => "11:1", "criterion" => "hardware", "source_revision" => "source-1", "intent_revision" => "intent-1" }
    ]
  end
  let(:assessor) { ->(submission:, **) { { "status" => "sufficient", "reason" => "current and applicable", "assessed_at" => Time.current.iso8601 } } }

  it "records actor, occurrence, revisions, provenance, and an explicit disposition" do
    result = described_class.call(notification:, actor:, prerequisite_id: "11:0", evidence_type: "artifact",
      reference: "https://example.test/pilot", explanation: "Pilot result covers the requested path.", assessor:)

    expect(result).to be_success
    submission = notification.reload.metadata.fetch("evidence_submissions").sole
    expect(submission).to include("prerequisite_id" => "11:0", "actor_id" => actor.id,
      "source_revision" => "source-1", "intent_revision" => "intent-1", "status" => "sufficient")
    expect(notification).to be_active
  end

  it "does not release an aggregate guard on partial sufficiency" do
    described_class.call(notification:, actor:, prerequisite_id: "11:0", evidence_type: "link",
      reference: "https://example.test/pilot", explanation: "Pilot result.", assessor:)

    expect(notification.reload.resolved_at).to be_nil
  end

  it "releases only after every occurrence has current sufficient evidence" do
    prerequisites.each do |prerequisite|
      described_class.call(notification:, actor:, prerequisite_id: prerequisite.fetch("id"), evidence_type: "link",
        reference: "https://example.test/#{prerequisite.fetch("id")}", explanation: "Evidence is applicable.", assessor:)
    end

    expect(notification.reload.resolved_at).to be_present
  end

  it "rejects an unknown occurrence without recording evidence" do
    result = described_class.call(notification:, actor:, prerequisite_id: "other", evidence_type: "link",
      reference: "https://example.test/evidence", explanation: "Evidence is applicable.", assessor:)

    expect(result).not_to be_success
    expect(notification.reload.metadata).not_to have_key("evidence_submissions")
  end
end
