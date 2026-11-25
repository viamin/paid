# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::LinkageFreshness do
  # @spec LAYERED-VERIFY-009
  it "records unmapped material and retains the bounded semantic-read limitation" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    run = create(:agent_run, project:, goal: "layered_verification_audit")

    result = described_class.call(agent_run: run, obligation:,
      structural_material: [ "app/services/refund.rb" ], semantic_material: [ "docs/intent/payments.md#refund" ])

    expect(result).to have_attributes(producer: "linkage_freshness", execution_state: "incomplete", obligation_coverage: "unresolved")
    expect(result.evidence_summary.fetch("unmapped_material")).to contain_exactly("docs/intent/payments.md#refund", "app/services/refund.rb")
    expect(result.recorder_verified).to eq("structural_unmapped_material" => [ "app/services/refund.rb" ])
    expect(result.agent_reported).to eq("semantic_unmapped_material" => [ "docs/intent/payments.md#refund" ])
    expect(result.limitations).to include("bounded semantic read-through")
  end

  # @spec LAYERED-VERIFY-009
  it "appends discovery limitations so an unexecutable structural diff is disclosed, not hidden" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    run = create(:agent_run, project:, goal: "layered_verification_audit")

    result = described_class.call(agent_run: run, obligation:, structural_material: [], semantic_material: [],
      limitations: [ "Structural discovery could not execute in the audit environment." ])

    expect(result.evidence_summary.fetch("unmapped_material")).to be_empty
    expect(result.limitations).to include("bounded semantic read-through", "Structural discovery could not execute")
  end
end
