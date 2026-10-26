# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "reports uncertainty when no result supports an obligation" do
    obligation = create(:layered_verification_obligation)
    run = create(:agent_run, project: obligation.project, goal: "layered_verification_audit", issue: nil)

    coverage = described_class.call(agent_run: run, obligations: [ obligation ]).first

    expect(coverage.verdict).to eq("unresolved")
  end
end
