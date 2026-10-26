# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::SynthesizeCoverage do
  # @spec LAYERED-VERIFY-024
  it "keeps an unresolved obligation explicit while independent supported evidence completes" do
    supported = create(:layered_verification_obligation)
    unresolved = create(:layered_verification_obligation, project: supported.project)
    create(:layered_verification_check_result, obligation: supported, obligation_coverage: "supported")
    create(:layered_verification_check_result, obligation: unresolved, obligation_coverage: "unresolved")

    report = described_class.call(obligations: [ supported, unresolved ])

    expect(report[:coverage]).to include(include(obligation_id: supported.id, verdict: "supported"))
    expect(report[:coverage]).to include(include(obligation_id: unresolved.id, verdict: "unresolved"))
    expect(report[:inbox_required]).to be(true)
  end
end
