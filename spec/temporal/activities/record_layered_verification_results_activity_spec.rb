# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordLayeredVerificationResultsActivity do
  def record_contradiction(audit, obligation)
    outcome = { obligation_id: obligation.id, selected_check: "semantic_audit", producer: "semantic_audit",
      execution_state: "completed", obligation_coverage: "contradicted", cause_signature: "missing-correspondence",
      input_revision: { code: "code-1", external_revision: "source-1" },
      evidence_summary: { passage: "Canonical clause", observation: "Conflicting implementation" },
      limitations: "Static source comparison; no behavioral tests." }
    audit.log!("stdout", "paid-layered-verification-output\n#{ { check_results: [ outcome ] }.to_json }\npaid-layered-verification-output\n")
    outcome
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "retains failed-audit evidence, findings and missing-check gaps without completing the run" do
    audit = create(:agent_run, :failed, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project, external_revision: "source-1")
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "code-1",
      "plan" => { obligation.id.to_s => { "selected_checks" => %w[semantic_audit implementation_conformance] } }
    } })
    outcome = record_contradiction(audit, obligation)

    2.times { described_class.new.execute(agent_run_id: audit.id) }

    expect(audit.reload.status).to eq("failed")
    expect(audit.external_metadata.dig("layered_verification", "coverage", obligation.id.to_s))
      .to include("obligation_coverage" => "contradicted")
    expect(obligation.check_results.count).to eq(2)
    expect(obligation.check_results.find_by!(producer: "implementation_conformance"))
      .to have_attributes(execution_state: "not_run", obligation_coverage: "unresolved")
    expect(obligation.findings.count).to eq(1)
    expect(obligation.findings.sole.source_passages).to include(outcome.fetch(:evidence_summary).stringify_keys)
    expect(audit.project.agent_runs.where(originating_audit_run_id: audit.id)).to be_empty
    expect(audit.pull_request_number).to be_nil
  end
end
