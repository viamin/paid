# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueEnhancements::TechnicalStopRecovery do
  let(:project) { create(:project, auto_enhance_enabled: true) }
  let(:issue) do
    create(:issue, :in_progress, project:, github_updated_at: Time.current.change(usec: 0), paid_state: "manual_review",
      manual_review_reason: "Paid could not validate the enhancement agent's structured output.")
  end
  let(:agent_run) do
    create(:agent_run, :failed, :automatic, :enhance_issue_goal, project:, issue:,
      error_message: "EnhanceIssue agent produced unparseable structured output: unexpected token")
  end

  before do
    agent_run.update!(external_metadata: {
      "prompt_assembly" => { "model" => "gpt-test" },
      described_class::METADATA_KEY => {
        "classification" => "parser", "issue_revision" => issue.github_updated_at.iso8601, "attempt" => 0
      }
    })
    allow(CostBudgets::Check).to receive(:call).with(project).and_return({ allowed: true })
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "creates one automatic successor and retains the failed parser evidence" do
    result = described_class.call(agent_run:)

    expect(result.outcome).to eq(:recovered)
    expect(result.successor).to have_attributes(goal: "enhance_issue", trigger_type: "automatic", status: "queued")
    expect(agent_run.reload.error_message).to include("unparseable structured output")
    expect(issue.reload.paid_state).to eq("in_progress")
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "claims the retry without clobbering sibling provenance metadata" do
    described_class.call(agent_run:)

    reloaded = agent_run.reload.external_metadata
    expect(reloaded["prompt_assembly"]).to eq({ "model" => "gpt-test" })
    expect(reloaded[described_class::METADATA_KEY]).to include(
      "classification" => "parser", "attempt" => 0, "recovery_claimed_at" => String
    )
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "does not retry when the issue changed after the technical stop" do
    issue.update!(github_updated_at: 1.minute.from_now)

    expect(described_class.call(agent_run:)).to have_attributes(outcome: :skipped, reason: :not_eligible)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "does not clear preserved human questions" do
    issue.update!(needs_input_questions: [ "Which behavior is required?" ])

    expect(described_class.call(agent_run:)).to have_attributes(outcome: :skipped, reason: :not_eligible)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "does not recover a manual-review stop owned by another producer" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(agent_run:)).to have_attributes(outcome: :skipped, reason: :not_eligible)
    expect(issue.reload).to have_attributes(
      paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON
    )
    expect(ProcessRunQueueJob).not_to have_received(:perform_later)
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "does not recover a manual-review stop with unknown technical provenance" do
    agent_run.update!(external_metadata: {
      described_class::METADATA_KEY => {
        "classification" => "unknown", "issue_revision" => issue.github_updated_at.iso8601, "attempt" => 0
      }
    })
    issue.update!(manual_review_reason: nil)

    expect(described_class.call(agent_run:)).to have_attributes(outcome: :skipped, reason: :not_eligible)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "does not retry a successor that exhausted its technical-stop budget" do
    agent_run.update!(external_metadata: {
      described_class::METADATA_KEY => {
        "classification" => "parser", "issue_revision" => issue.github_updated_at.iso8601, "attempt" => 1
      }
    })

    expect(described_class.call(agent_run:)).to have_attributes(outcome: :skipped, reason: :not_eligible)
  end

  # @spec ISSUE-ENHANCEMENT-021
  it "honors a project policy that opts out of automatic issue preparation" do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(Automation::PhaseSettings::SETTINGS_KEY => {
      Automation::PhaseSettings::PHASES_KEY => { Automation::Phases::ISSUE_PREPARATION => false },
      Automation::PhaseSettings::RELEASE_KEY => false,
      Automation::PhaseSettings::DEPLOYMENT_KEY => false
    })

    expect(described_class.call(agent_run:)).to have_attributes(outcome: :skipped, reason: :not_eligible)
    expect(issue.reload.paid_state).to eq("manual_review")
  end
end
