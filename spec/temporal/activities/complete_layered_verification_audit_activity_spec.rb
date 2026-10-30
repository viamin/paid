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

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "ingests agent outcomes before synthesis without preseeded results" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ],
        "target_revision" => "abc123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } }
      }
    })
    audit.log!("stdout", <<~OUTPUT)
      paid-layered-verification-output
      {"check_results":[{"obligation_id":#{obligation.id},"selected_check":"semantic_audit","producer":"semantic_audit","execution_state":"completed","obligation_coverage":"supported","input_revision":{"code":"abc123"},"evidence_summary":{"source_passages":["PAYMENTS-001"]},"limitations":"Bounded to the selected obligation."}]}
      paid-layered-verification-output
    OUTPUT

    response = described_class.new.execute(agent_run_id: audit.id)

    result = obligation.check_results.sole
    expect(result).to have_attributes(agent_run: audit, producer: "semantic_audit",
      execution_state: "completed", obligation_coverage: "supported")
    expect(response.dig(:coverage, obligation.id.to_s, :check_result_ids)).to eq([ result.id ])
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "downgrades agent outcomes reported against the wrong revision" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project, external_revision: "intent123")
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ],
        "target_revision" => "code123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } }
      }
    })
    audit.log!("stdout", <<~OUTPUT)
      paid-layered-verification-output
      {"check_results":[{"obligation_id":#{obligation.id},"selected_check":"semantic_audit","producer":"semantic_audit","execution_state":"completed","obligation_coverage":"contradicted","input_revision":{"external_revision":"intent123","code":"wrong-code"},"evidence_summary":{"source_passages":["PAYMENTS-001"]},"cause_signature":"wrong-behavior","limitations":"Bounded to the selected obligation."}]}
      paid-layered-verification-output
    OUTPUT

    response = described_class.new.execute(agent_run_id: audit.id)

    result = obligation.check_results.sole
    expect(result).to have_attributes(execution_state: "stale", obligation_coverage: "unresolved")
    expect(result.limitations).to include("reported input revision does not match")
    expect(response.dig(:coverage, obligation.id.to_s, :obligation_coverage)).to eq("unresolved")
    expect(LayeredVerificationFinding.where(obligation:)).to be_empty
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "downgrades agent outcomes that omit their input revision" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ],
        "target_revision" => "abc123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } }
      }
    })
    audit.log!("stdout", <<~OUTPUT)
      paid-layered-verification-output
      {"check_results":[{"obligation_id":#{obligation.id},"selected_check":"semantic_audit","producer":"semantic_audit","execution_state":"completed","obligation_coverage":"supported","input_revision":{},"evidence_summary":{},"limitations":"Bounded to the selected obligation."}]}
      paid-layered-verification-output
    OUTPUT

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.sole).to have_attributes(
      execution_state: "stale", obligation_coverage: "unresolved"
    )
  end

  # @spec LAYERED-VERIFY-024
  it "records selected checks omitted from agent output as not run" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ],
        "target_revision" => "abc123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ] } }
      }
    })

    described_class.new.execute(agent_run_id: audit.id)

    expect(obligation.check_results.sole).to have_attributes(
      execution_state: "not_run", obligation_coverage: "unresolved",
      limitations: "The selected check did not produce a recorded outcome."
    )
  end

  # @spec LAYERED-VERIFY-023 LAYERED-VERIFY-024
  it "binds the completed audit to a review package without starting repair" do
    audit = create(:agent_run, goal: "layered_verification_audit", status: "running")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ],
        "target_revision" => "abc123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } }
      }
    })

    described_class.new.execute(agent_run_id: audit.id)

    package = LayeredVerificationReviewPackage.sole
    expect(package).to have_attributes(agent_run: audit, revision: 1)
    expect(package.bound_inputs.dig("scope", "target_revision")).to eq("abc123")
    expect(AgentRun.where(goal: "layered_verification_repair", project: audit.project)).to be_empty
  end
end
