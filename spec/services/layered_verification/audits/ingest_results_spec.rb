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

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "preserves newline-free log record boundaries for the harness normalizer" do
    audit, obligation = audit_with_selected_check
    record_output(audit, obligation)
    output = audit.agent_run_logs.stdout.sole.content
    audit.agent_run_logs.stdout.delete_all
    records = [ { type: "progress" }.to_json, { type: "answer", text: output }.to_json ]
    records.each { |record| audit.log!("stdout", record) }
    # This is a transport-independent normalizer seam, not a Paid-side
    # provider parser. Each stored row is a complete event without a newline.
    allow(audit).to receive(:normalized_agent_output) do |raw, succeeded:|
      expect(succeeded).to be(true)
      raw.lines.filter_map do |line|
        parsed = JSON.parse(line)
        parsed["text"] if parsed["type"] == "answer"
      rescue JSON::ParserError
        nil
      end.join("\n")
    end

    described_class.call(agent_run: audit)

    expect(obligation.check_results.sole).to have_attributes(
      execution_state: "completed", obligation_coverage: "supported")
    expect(audit).to have_received(:normalized_agent_output).with(records.join("\n"), succeeded: true)
  end

  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  it "also preserves continuous plaintext output split inside a JSON string" do
    audit, obligation = audit_with_selected_check
    record_output(audit, obligation, evidence_summary: { observation: "Evidence crossing a chunk boundary" })
    output = audit.agent_run_logs.stdout.sole.content
    audit.agent_run_logs.stdout.delete_all
    split = output.index("crossing") + 3
    audit.log!("stdout", output.first(split))
    audit.log!("stdout", output[split..])

    described_class.call(agent_run: audit)

    expect(obligation.check_results.sole).to have_attributes(
      execution_state: "completed", obligation_coverage: "supported")
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
