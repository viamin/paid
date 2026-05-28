# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::RecordRemediationDecision do
  let(:account) { create(:account) }
  let(:pattern) do
    AgentRunPatterns::Detect::Pattern.new(
      type: :error_cluster,
      goal: "enhance_issue",
      severity: :error,
      details: {
        fingerprint: "fingerprint-1",
        occurrence_count: 3
      }
    )
  end
  let(:diagnosis) do
    AgentRunPatterns::Diagnose::Diagnosis.new(
      root_cause: "GitHub API quota exhausted",
      confidence: 0.9,
      proposed_action: "mark_runner_unavailable",
      action_target: { "type" => "runner", "id" => "42" },
      evidence_pointers: [ "runner_attempts[0].error_message" ]
    )
  end

  it "creates a proposed remediation decision" do
    decision = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    expect(decision).to have_attributes(
      account: account,
      fingerprint: "fingerprint-1",
      root_cause: "GitHub API quota exhausted",
      proposed_action: "mark_runner_unavailable",
      action_target_type: "runner",
      action_target_id: "42",
      status: "proposed",
      occurrence_count: 1,
      pre_remediation_failure_count: 3
    )
  end

  it "dedupes the same fingerprint within 24 hours and increments occurrence_count" do
    first = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    second = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    expect(second.id).to eq(first.id)
    expect(second.reload.occurrence_count).to eq(2)
  end

  it "creates a new decision after the prior one moves past proposed" do
    decision = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)
    decision.update!(
      status: "applied",
      revert_data: { "command" => "bin/self-heal revert 123" },
      post_remediation_failure_count: 1,
      outcome: "improved"
    )

    replacement = nil
    expect {
      replacement = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)
    }.to change(RemediationDecision, :count).by(1)
    expect(replacement.id).not_to eq(decision.id)
    expect(decision.reload).to have_attributes(
      status: "applied",
      revert_data: { "command" => "bin/self-heal revert 123" },
      post_remediation_failure_count: 1,
      outcome: "improved",
      occurrence_count: 1
    )
  end

  it "leaves non-proposed decisions immutable when recording a repeated fingerprint" do
    decision = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)
    decision.update!(status: "applied")

    replacement = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    expect(replacement.reload).to have_attributes(
      status: "proposed",
      occurrence_count: 1,
      proposed_action: "mark_runner_unavailable"
    )
    expect(decision.reload).to have_attributes(status: "applied", occurrence_count: 1)
  end
end
