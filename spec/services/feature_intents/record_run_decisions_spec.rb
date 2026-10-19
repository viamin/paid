# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-019
RSpec.describe FeatureIntents::RecordRunDecisions do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:brief_issue) { create(:issue, project: project) }
  let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }
  let(:agent_run) { create(:agent_run, project: project, issue: brief_issue, goal: "create_feature") }

  def record_stdout(content)
    agent_run.log!("stdout", content)
  end

  def decisions_summary
    <<~TEXT
      Opened the RDR PR.

      <!-- feature-decisions-start -->
      [
        {"kind": "question", "design_claim": "Dark mode applies to the settings UI", "prompt": "Should dark mode apply to the marketing pages too?"},
        {"kind": "inferred_decision", "design_claim": "Theme persistence is per user", "prompt": "Persisting the theme choice per user account."}
      ]
      <!-- feature-decisions-end -->
    TEXT
  end

  it "records a FeatureIntentDecision row per explicitly emitted decision, bound to the run" do
    record_stdout(decisions_summary)

    result = described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(result.recorded_count).to eq(2)
    decisions = feature_intent.feature_intent_decisions.order(:id)
    expect(decisions.count).to eq(2)
    expect(decisions.find { |d| d.question? }).to have_attributes(
      design_claim: "Dark mode applies to the settings UI",
      prompt: "Should dark mode apply to the marketing pages too?",
      status: "open",
      source_agent_run_id: agent_run.id
    )
    expect(decisions.find { |d| d.inferred_decision? }).to have_attributes(
      prompt: "[inferred] Persisting the theme choice per user account.",
      source_agent_run_id: agent_run.id
    )
  end

  it "records no rows when the run emitted no decisions (no fabrication)" do
    record_stdout("Researched the repo and opened the RDR PR. Nothing left to ask.")

    result = described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(result.recorded_count).to eq(0)
    expect(feature_intent.feature_intent_decisions).to be_empty
  end

  it "records no rows when the run produced no output" do
    result = described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(result.recorded_count).to eq(0)
    expect(feature_intent.feature_intent_decisions).to be_empty
  end

  it "is idempotent per run — recording twice does not duplicate rows" do
    record_stdout(decisions_summary)

    described_class.call(feature_intent: feature_intent, agent_run: agent_run)
    result = described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(result.recorded_count).to eq(0)
    expect(feature_intent.feature_intent_decisions.count).to eq(2)
  end

  it "records decisions from a second (chained lid_planning) run alongside the first run's" do
    record_stdout(decisions_summary)
    described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    chained_run = create(:agent_run, project: project, issue: brief_issue, goal: "lid_planning")
    chained_run.log!("stdout", <<~TEXT)
      <!-- feature-decisions-start -->
      [{"kind": "inferred_decision", "design_claim": "Cascade ordering", "prompt": "Auth lands before billing."}]
      <!-- feature-decisions-end -->
    TEXT
    result = described_class.call(feature_intent: feature_intent, agent_run: chained_run)

    expect(result.recorded_count).to eq(1)
    expect(feature_intent.feature_intent_decisions.count).to eq(3)
  end

  it "moves the feature to needs_decision when open decisions are recorded" do
    record_stdout(decisions_summary)

    described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(feature_intent.reload.status).to eq("needs_decision")
  end

  it "moves a ready_for_approval feature back to needs_decision" do
    feature_intent.update!(status: "ready_for_approval")
    record_stdout(decisions_summary)

    described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(feature_intent.reload.status).to eq("needs_decision")
  end

  it "does not transition a discovering, approved, or terminal feature" do
    record_stdout(decisions_summary)

    statuses = %w[discovering approved_waiting_for_merge released cancelled]
    statuses.each do |status|
      intent = create(:feature_intent, :ready_for_approval, project: project, status: status)

      described_class.call(feature_intent: intent, agent_run: agent_run)

      expect(intent.reload.status).to eq(status)
    end
  end

  it "does not transition when every emitted decision parsed as invalid" do
    record_stdout(<<~TEXT)
      <!-- feature-decisions-start -->
      [{"kind": "question", "design_claim": "Missing prompt"}]
      <!-- feature-decisions-end -->
    TEXT

    described_class.call(feature_intent: feature_intent, agent_run: agent_run)

    expect(feature_intent.reload.status).to eq("design_open")
  end
end
