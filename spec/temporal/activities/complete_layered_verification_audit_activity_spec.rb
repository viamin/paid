# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteLayeredVerificationAuditActivity do
  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-024
  it "synthesizes scoped coverage and completes the assessment-only run" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: {
      "layered_verification" => { "obligation_ids" => [ obligation.id ] }
    })
    result = create(:layered_verification_check_result, obligation:, agent_run: audit,
      obligation_coverage: "supported", limitations: "bounded input")

    response = described_class.new.execute(agent_run_id: audit.id)

    expect(response).to include(agent_run_id: audit.id, success: true)
    expect(response.dig(:coverage, obligation.id.to_s)).to eq(
      obligation_coverage: "supported", check_result_ids: [ result.id ]
    )
    expect(audit.reload.status).to eq("completed")
  end
end
