# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-004 @spec BOUNDED-PHASE-AUTHORIZATION-009
RSpec.describe Automation::AdmissionSnapshot do
  let(:project) { create(:project, delegation_posture: "bounded_delivery", delegation_posture_revision: 3) }
  let(:run) { create(:agent_run, project:) }
  let(:arguments) do
    {
      agent_run: run, posture: "bounded_delivery", intent_revision: "intent-2",
      acceptance_revision: "acceptance-4", evidence_revision: "evidence-7",
      policy_signature: "policy-3", phase: "coding"
    }
  end

  it "captures a write-once posture and evidence receipt" do
    snapshot = described_class.capture(**arguments)

    expect(run.reload.admission_snapshot).to include(
      "posture" => "bounded_delivery", "posture_revision" => 3,
      "intent_revision" => "intent-2", "evidence_revision" => "evidence-7"
    )
    expect(snapshot).to eq(run.admission_snapshot)
    expect {
      described_class.capture(**arguments.merge(evidence_revision: "evidence-8"))
    }.not_to change { run.reload.admission_snapshot }
  end

  it "blocks a changed revision without broadening the admitted run" do
    described_class.capture(**arguments)

    decision = described_class.check(**arguments.merge(evidence_revision: "evidence-8"))

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq(:revision_changed)
  end

  it "rejects a held admission at the next boundary" do
    described_class.capture(**arguments)
    Automation::AdmissionLifecycle.call(agent_run: run, transition: :hold, reason: "operator hold")

    decision = described_class.check(**arguments)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq(:held)
  end
end
