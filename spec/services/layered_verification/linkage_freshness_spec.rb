# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::LinkageFreshness do
  # @spec LAYERED-VERIFY-009
  it "records unmapped material and retains the bounded semantic-read limitation" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    run = create(:agent_run, project:, goal: "layered_verification_audit")

    result = described_class.call(agent_run: run, obligation:, material: [ "docs/intent/payments.md#refund", "app/services/refund.rb" ])

    expect(result).to have_attributes(producer: "linkage_freshness", execution_state: "incomplete", obligation_coverage: "unresolved")
    expect(result.evidence_summary.fetch("unmapped_material")).to contain_exactly("docs/intent/payments.md#refund", "app/services/refund.rb")
    expect(result.limitations).to include("bounded semantic read-through")
  end
end
