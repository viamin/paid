# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::IngestResults do
  def audit_with_selected_check
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project, external_revision: "b" * 40)
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "a" * 40,
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } }
    } })
    [ audit, obligation ]
  end

  def record_output(audit, obligation, **attributes)
    outcome = { obligation_id: obligation.id, selected_check: "semantic_audit", producer: "semantic_audit",
      execution_state: "completed", obligation_coverage: "supported",
      input_revision: { code: "a" * 40, external_revision: "b" * 40 }, limitations: "Static assessment only." }
      .merge(attributes)
    audit.log!("stdout", "paid-layered-verification-output\n#{ { check_results: [ outcome ] }.to_json }\npaid-layered-verification-output\n")
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "preserves reported evidence lists without accepting agent-supplied recorder facts" do
    audit, obligation = audit_with_selected_check
    record_output(audit, obligation, evidence_summary: [ "Source clause", "Observed behavior" ],
      evidence_ref: [ "docs/spec.md:1", "app/worker.rb:2" ], limitations: [ "Static only", "Tests not run" ],
      recorder_verified: { source_authority: true })

    described_class.call(agent_run: audit)

    result = obligation.check_results.sole
    expect(result.evidence_summary).to eq("observations" => [ "Source clause", "Observed behavior" ])
    expect(result.evidence_ref).to eq("docs/spec.md:1\napp/worker.rb:2")
    expect(result.limitations).to eq("Static only\nTests not run")
    expect(result.recorder_verified).to eq("structured_output" => true)
  end

  # @spec LAYERED-VERIFY-024
  it "rejects exchanged code and obligation-source revision values" do
    audit, obligation = audit_with_selected_check
    record_output(audit, obligation, input_revision: { code: "b" * 40, external_revision: "a" * 40 })

    described_class.call(agent_run: audit)

    expect(obligation.check_results.sole).to have_attributes(execution_state: "stale", obligation_coverage: "unresolved")
  end

  # @spec LAYERED-VERIFY-024
  it "requires the named source revision even when it equals the code revision" do
    audit, obligation = audit_with_selected_check
    obligation.update!(external_revision: "a" * 40)
    record_output(audit, obligation, input_revision: { code: "a" * 40 })

    described_class.call(agent_run: audit)

    expect(obligation.check_results.sole).to have_attributes(execution_state: "stale", obligation_coverage: "unresolved")
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-022 LAYERED-VERIFY-024
  it "does not replace a recorder-owned formal result with an agent report" do
    audit = create(:agent_run, goal: "layered_verification_audit")
    obligation = create(:layered_verification_obligation, project: audit.project)
    audit.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "abc123",
      "plan" => { obligation.id.to_s => { "selected_checks" => [ "formal_verification" ] } }
    } })
    recorded = create(:layered_verification_check_result, obligation:, agent_run: audit,
      agent_reported: { "selected_check" => "formal_verification" })
    audit.log!("stdout", "paid-layered-verification-output\n" \
      "{\"check_results\":[{\"obligation_id\":#{obligation.id},\"selected_check\":\"formal_verification\"}]}\n" \
      "paid-layered-verification-output\n")

    described_class.call(agent_run: audit)

    expect(obligation.check_results).to contain_exactly(recorded)
  end
end
