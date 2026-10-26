# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::RecordReviewPackage do
  # @spec LAYERED-VERIFY-023
  it "records the bound review inputs without approving repair work" do
    project = create(:project)
    run = create(:agent_run, project:, goal: "layered_verification_audit")
    audit = create(:layered_verification_audit, project:, agent_run: run)
    obligation = create(:layered_verification_obligation, project:)
    result = create(:layered_verification_check_result, obligation:, agent_run: run)

    package = described_class.call(audit:, obligations: [ obligation ], check_results: [ result ])

    expect(package).to be_persisted
    expect(package).not_to be_approved
    expect(package.check_result_ids).to eq([ result.id ])
  end
end
