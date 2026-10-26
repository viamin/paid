# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "records an unresolved coverage view when selected checks cannot support an obligation" do
    audit_run = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit_run.project)
    create(:layered_verification_check_result, obligation:, agent_run: audit_run,
      execution_state: "non_applicable", obligation_coverage: "unresolved", limitations: "No model declared")

    coverage = described_class.call(audit_run:, obligations: [ obligation ])

    expect(coverage.fetch(obligation.id)).to eq("unresolved")
    expect(audit_run.reload.verification_result.fetch("coverage").fetch(obligation.id.to_s)).to eq("unresolved")
  end
end
