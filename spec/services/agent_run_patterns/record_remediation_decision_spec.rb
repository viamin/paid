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
      pre_remediation_failure_count: 3,
      diagnosis_attempted_on: Date.current,
      diagnosis_attempt_count_on_day: 1
    )
  end

  it "dedupes the same fingerprint within 24 hours and increments occurrence_count" do
    first = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    second = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    expect(second.id).to eq(first.id)
    expect(second.reload.occurrence_count).to eq(2)
    expect(second.diagnosis_attempt_count_on_day).to eq(2)
  end

  it "creates a separate decision when the repeated fingerprint targets a different runner" do
    described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

    other_diagnosis = diagnosis.with(action_target: { "type" => "runner", "id" => "43" })

    expect {
      described_class.call(account: account, pattern: pattern, diagnosis: other_diagnosis)
    }.to change(RemediationDecision, :count).by(1)
  end

  it "creates a separate decision when the repeated fingerprint targets a different runner field" do
    field_diagnosis = diagnosis.with(
      proposed_action: "clear_runner_field",
      action_target: { "type" => "runner_field", "id" => "42", "field_name" => "model" }
    )
    described_class.call(account: account, pattern: pattern, diagnosis: field_diagnosis)

    other_field_diagnosis = field_diagnosis.with(
      action_target: { "type" => "runner_field", "id" => "42", "field_name" => "fallback_runner" }
    )

    expect {
      described_class.call(account: account, pattern: pattern, diagnosis: other_field_diagnosis)
    }.to change(RemediationDecision, :count).by(1)
  end

  it "resets the per-day diagnosis attempt counter on a new day" do
    freeze_time do
      decision = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

      travel 1.day

      repeated = described_class.call(account: account, pattern: pattern, diagnosis: diagnosis)

      expect(repeated.id).to eq(decision.id)
      expect(repeated.reload).to have_attributes(
        occurrence_count: 2,
        diagnosis_attempted_on: Date.current,
        diagnosis_attempt_count_on_day: 1
      )
    end
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
