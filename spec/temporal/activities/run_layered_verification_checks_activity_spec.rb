# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunLayeredVerificationChecksActivity do
  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-022 LAYERED-VERIFY-024
  it "runs a selected TLC check in the audit container and persists its parsed result" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project, external_revision: "intent123")
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "code123",
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ],
        "required_inputs" => [ "model/Checkout.tla", "model/Checkout.cfg" ] } }
    } })
    command_result = Containers::Provision::Result.success(
      stdout: "Error: Invariant Safety is violated.\n", stderr: "", exit_code: 12
    )
    allow(audit).to receive(:execute_in_execution_environment).with(
      [ "tlc", "-config", "model/Checkout.cfg", "model/Checkout.tla" ], timeout: 60, stream: false
    ).and_return(command_result)
    allow(AgentRun).to receive(:find).with(audit.id).and_return(audit)

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.sole).to have_attributes(
      agent_run: audit, producer: "formal_verification", execution_state: "completed",
      obligation_coverage: "contradicted", cause_signature: "tlc-invariant-violation"
    )
  end

  it "records a selected formal check without a declared pair as non-applicable" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "code123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ] } }
      }
    })

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.sole).to have_attributes(
      execution_state: "non_applicable", obligation_coverage: "unresolved",
      limitations: "no declared TLA+ model/config pair"
    )
  end
end
