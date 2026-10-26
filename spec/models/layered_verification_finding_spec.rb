# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "adds repeated evidence to the same unresolved scoped cause" do
    obligation = create(:layered_verification_obligation)
    audit = create(:agent_run, project: obligation.project, goal: "layered_verification_audit", issue: nil)
    result_one = create(:layered_verification_check_result, obligation:, agent_run: audit, obligation_coverage: "contradicted")
    result_two = create(:layered_verification_check_result, obligation:, agent_run: audit, obligation_coverage: "contradicted")
    attributes = {
      project_id: obligation.project_id, obligation_id: obligation.id,
      correspondence_claim_type: "business_to_spec", cause_signature: "missing-owner-rule",
      source_passages: [ { "reference" => "intent.md:10" } ], observed_behavior: "Code accepts any owner.",
      check_limitations: "No production traffic sample.", question: "Which owner rule is canonical?",
      options: [], consequences: [], owner_actions: []
    }

    finding = described_class.record!(attributes:, check_result: result_one, agent_run: audit)

    expect { described_class.record!(attributes:, check_result: result_two, agent_run: audit) }
      .not_to change(described_class, :count)
    expect(finding.reload.observations).to contain_exactly(have_attributes(check_result: result_one), have_attributes(check_result: result_two))
  end
end
