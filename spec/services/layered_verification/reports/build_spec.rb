# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Reports::Build do
  # @spec LAYERED-VERIFY-006 @spec LAYERED-VERIFY-024
  it "keeps business-intent validation separate from verification coverage" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, approval_state: "unresolved")
    run = create(:agent_run, project:, goal: "layered_verification_audit", external_metadata: {
      "layered_verification" => { "obligation_ids" => [ obligation.id ], "target_revision" => "abc123", "budget_tokens" => 12_000 }
    })
    create(:layered_verification_check_result, obligation:, agent_run: run, producer: "behavioral_testing",
      execution_state: "completed", obligation_coverage: "supported", limitations: "example coverage only")

    report = described_class.call(run:)

    expect(report.fetch("business_intent_validation")).to include(include("approval_state" => "unresolved"))
    expect(report.fetch("verification_coverage")).to include(include("coverage" => "supported"))
    expect(report).to include("target_revision" => "abc123", "budget_tokens" => 12_000)
  end
end
