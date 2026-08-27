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
      evidence_pointers: [ "runner_attempts[0].error_message" ]
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

  it "auto-applies the first remediation and leaves later runs proposed after an unchanged outcome" do
    first_decision = perform_detection_cycle

    expect_first_decision_to_be_auto_applied(first_decision)

    RemediationDecisionOutcomeJob.perform_now

    expect_unchanged_outcome(first_decision)

    follow_up_decision = perform_detection_cycle(expected_activity_delta: 0)

    expect_follow_up_decision_to_remain_proposed(follow_up_decision)
  end

  def perform_detection_cycle(expected_decision_delta: 1, expected_activity_delta: 1)
    expect {
      described_class.perform_now
    }.to change(RemediationDecision, :count).by(expected_decision_delta)
      .and change(AccountActivityEvent, :count).by(expected_activity_delta)

    RemediationDecision.order(:id).last
  end

  def expect_first_decision_to_be_auto_applied(decision)
    expect(decision).to have_attributes(
      status: "applied",
      proposed_action: "mark_runner_unavailable",
      outcome: nil
    )
    expect(owner.runner_states.find_by!(runner_name: runner.state_key)).to be_rate_limited
    expect(decision.revert_data).to include(
      "handler" => "mark_runner_unavailable",
      "runner_id" => runner.id
    )
    expect(account.account_activity_events.recent.first.action).to eq("self_heal.remediation_applied")
  end

  def expect_unchanged_outcome(decision)
    expect(decision.reload).to have_attributes(
      outcome: "unchanged",
      post_remediation_failure_count: 3
    )
  end

  def expect_follow_up_decision_to_remain_proposed(decision)
    expect(decision).to have_attributes(
      status: "proposed",
      proposed_action: "mark_runner_unavailable",
      outcome: nil
    )
  end
end
