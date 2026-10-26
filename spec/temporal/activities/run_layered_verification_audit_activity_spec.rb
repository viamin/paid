# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunLayeredVerificationAuditActivity do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  # @spec LAYERED-VERIFY-021 @spec LAYERED-VERIFY-024
  it "records an explicit unresolved coverage result and completes without repair" do
    obligation = create(:layered_verification_obligation, project:, external_identity: "PAYMENTS-001")
    run = create(:agent_run, :queued, project:, goal: "layered_verification_audit", initiating_user: user,
      reconciliation: { "layered_verification_audit" => { "scope" => [ obligation.external_identity ],
        "source_references" => [ "docs/intent/payments.md" ], "target_revision" => "abc123", "budget" => 1200 } })

    described_class.new.execute(agent_run_id: run.id)

    result = LayeredVerificationCheckResult.find_by!(agent_run: run)
    expect(result).to have_attributes(producer: "verification_planning", execution_state: "non_applicable", obligation_coverage: "unresolved")
    expect(run.reload.status).to eq("completed")
    expect(AgentRun.where(goal: "layered_verification_repair")).to be_empty
  end
end
