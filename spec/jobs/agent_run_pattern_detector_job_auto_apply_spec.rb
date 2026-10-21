# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatternDetectorJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:runner) do
    create(
      :runner,
      user: owner,
      runner_key: "cursor",
      enabled_for_agent_runs: true,
      enabled_for_fallback: true
    )
  end
  let(:pattern) do
    AgentRunPatterns::Detect::Pattern.new(
      type: :error_cluster,
      goal: "enhance_issue",
      severity: :error,
      details: {
        fingerprint: "runner-rate-limit-fingerprint",
        occurrence_count: 3
      }
    )
  end
  let(:diagnosis) do
    AgentRunPatterns::Diagnose::Diagnosis.new(
      root_cause: "Runner quota exhausted",
      confidence: 0.92,
      proposed_action: "mark_runner_unavailable",
      action_target: { "type" => "runner", "id" => runner.id.to_s },
      evidence_pointers: [ "runner_attempts[0].error_message" ],
      obstacle_kind: "infrastructure_configuration",
      validation_plan: "Review the proposal.",
      uncertainty: "Evidence is limited."
    )
  end

  before do
    account.update!(
      remediation_policy: {
        "mark_runner_unavailable" => {
          "mode" => "auto_apply",
          "minimum_confidence" => 0.8,
          "filing_threshold" => 1
        }
      }
    )

    allow(AgentRunPatterns::Detect).to receive(:call).and_return([])
    allow(AgentRunPatterns::Detect).to receive(:call).with(account: account).and_return([ pattern ])
    allow(AgentRunPatterns::Diagnose).to receive(:call).and_return(diagnosis)
  end

  # @spec RUN-OBSTACLE-004
  it "records a proposal without applying a remediation even when an account has an old auto-apply policy" do
    first_decision = perform_detection_cycle(expected_activity_delta: 0)

    expect(first_decision).to have_attributes(
      status: "proposed",
      proposed_action: "mark_runner_unavailable",
      outcome: nil
    )
    expect(owner.runner_states.find_by(runner_name: runner.state_key)).to be_nil
    expect(account.account_activity_events).to be_empty
  end

  def perform_detection_cycle(expected_decision_delta: 1, expected_activity_delta: 1)
    expect {
      described_class.perform_now
    }.to change(RemediationDecision, :count).by(expected_decision_delta)
      .and change(AccountActivityEvent, :count).by(expected_activity_delta)

    RemediationDecision.order(:id).last
  end
end
