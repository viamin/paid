# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitPrerequisiteEvidence do
  let(:project) { create(:project) }
  let(:actor) { create(:user, account: project.account) }
  let(:issue) { create(:issue, :in_progress, project:, github_state: "open") }

  def record_assessment(criterion: "Production pilot")
    run = create(:agent_run, :completed, project:, issue:)
    assessment = { "criteria" => [ { "criterion" => criterion, "state" => "unknown", "prerequisite_kind" => "human" } ] }
    run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(run, assessment) })
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records attributable evidence only for an exact current prerequisite" do
    record_assessment

    result = described_class.call(issue:, actor:, criterion: "Production pilot", evidence_type: "link",
      evidence_reference: "https://evidence.example/pilot", explanation: "Pilot result for the production gate.", idempotency_key: "pilot-1")

    expect(result).to be_success
    expect(result.evidence).to have_attributes(outcome: "submitted", actor:, issue:, criterion: "Production pilot")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "rejects an arbitrary link for a different prerequisite" do
    record_assessment

    result = described_class.call(issue:, actor:, criterion: "Unrelated approval", evidence_type: "link",
      evidence_reference: "https://evidence.example/no", explanation: "Not applicable.", idempotency_key: "pilot-2")

    expect(result).not_to be_success
    expect(PartialCloseoutPrerequisiteEvidence.count).to eq(0)
  end
end
