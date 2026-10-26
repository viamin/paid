# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "reports missing check evidence as unresolved rather than support" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    run = create(:agent_run, project:, issue: nil, goal: "layered_verification_audit",
      external_metadata: { "layered_verification_audit" => { "obligation_ids" => [ obligation.id ] } })

    result = described_class.call(agent_run: run)

    expect(result).to contain_exactly(include(obligation:, coverage: "unresolved", results: []))
  end
end
