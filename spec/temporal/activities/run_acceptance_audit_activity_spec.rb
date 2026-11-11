# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAcceptanceAuditActivity do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:run) { create(:agent_run, :queued, project:, issue:, goal: "analyze_issue") }

  # @spec PARTIAL-CLOSEOUT-027 PARTIAL-CLOSEOUT-035
  it "persists a refreshed report without changing issue state" do
    issue.update!(paid_state: "in_progress")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.reconciliation.dig("assessment", "source_revision")).to be_present
    expect(run.reload.reconciliation).to include("status" => "reconciled")
    expect(run.reload.status).to eq("completed")
    expect(issue.reload.paid_state).to eq("in_progress")
    expect(AutoResolveCloseoutJob).not_to have_been_enqueued
  end

  # @spec PROJECT-DELEGATION-009
  it "queues a closeout check only for an audit that captured delegated authority" do
    request = create(:issue_continuation_request, issue:, project:, requested_by: user,
      evidence: { "closeout_policy_signature" => "captured" })
    run.update!(continuation_request: request)
    allow(Llm::AnalyzePartialCloseout).to receive(:call).with(
      agent_run: run, fallback_runner_identifiers: [], timeout: 60
    ).and_return({ "gaps" => [] })

    described_class.new.execute(agent_run_id: run.id)

    expect(AutoResolveCloseoutJob).to have_been_enqueued.with(run.id)
  end

  # @spec PARTIAL-CLOSEOUT-035
  it "records operator prerequisites before completing a report with gaps" do
    issue.update!(paid_state: "in_progress")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(
      "gaps" => [ { "criterion" => "macOS acceptance", "kind" => "human",
        "next_step" => "Run the approved macOS pilot.",
        "attribution" => { "coverage" => "established", "source_issue_number" => issue.github_number,
          "owner_issue_number" => issue.github_number, "criterion" => "macOS acceptance" } } ]
    )

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.reconciliation).to include("status" => "awaiting_operator")
    expect(Notification.where(subject: issue, blocking: true)).to exist
    expect(issue.reload.paid_state).to eq("in_progress")
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "passes configured fallback runners to a bounded audit assessment" do
    primary = create(:runner, user: user, runner_key: "codex")
    create(:runner, user: user, runner_key: "gemini")
    run.update!(runner: primary)
    user.settings.update!(fallback_enabled: true, issue_analysis_fallback_runners: [ "gemini" ])
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

    described_class.new.execute(agent_run_id: run.id)

    expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(
      agent_run: run, fallback_runner_identifiers: array_including("gemini"), timeout: be_between(120, 300))
  end

  # @spec PARTIAL-CLOSEOUT-049
  it "does not pass fallback runners when fallback is disabled" do
    user.settings.update!(fallback_enabled: false, issue_analysis_fallback_runners: [ "gemini" ])
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

    described_class.new.execute(agent_run_id: run.id)

    expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(
      agent_run: run, fallback_runner_identifiers: [], timeout: 60)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "records a typed transient assessment failure for the retry sweep" do
    failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("Transport failed", category: "transport_error")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

    expect { described_class.new.execute(agent_run_id: run.id) }.to raise_error(failure)
    expect(run.reload.reconciliation.dig("acceptance_audit_failure", "category")).to eq("transport_error")
    expect(run.reconciliation).not_to have_key("assessment")
  end
end
