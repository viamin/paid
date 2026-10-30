# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-018
RSpec.describe AgentPlanningHolds::Capture do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }
  let(:run) { create(:agent_run, :failed, project:) }

  it "upserts a failed run's contracted hold without duplicating retries" do
    contract = {
      task_kind: "implementation",
      reason: "Awaiting a prerequisite issue.",
      release_condition: { kind: "issue_closed", issue_number: issue.github_number + 1 },
      evidence: { scope_revision: "rdr-063@draft", issue_number: issue.github_number }
    }

    2.times do
      described_class.call(project:, agent_run: run, issue_number: issue.github_number, contract:, label_preexisting: false)
    end

    hold = AgentPlanningHold.find_by!(issue:, label: "planning")
    expect(AgentPlanningHold.where(issue:, label: "planning")).to contain_exactly(hold)
    expect(hold).to have_attributes(status: "held", task_kind: "implementation", agent_run: run)
    expect(hold.release_condition).to include("kind" => "issue_closed")
  end

  it "keeps an unknown same-number issue out of another tenant's hold" do
    other_project = create(:project)
    other_run = create(:agent_run, :failed, project: other_project)

    expect {
      described_class.call(project: other_project, agent_run: other_run, issue_number: issue.github_number,
        label_preexisting: false)
    }.to change(AgentPlanningHold, :count).by(1)

    expect(AgentPlanningHold.last).to have_attributes(project: other_project, issue: nil)
  end

  it "rejects a run from another tenant" do
    other_project = create(:project)

    expect {
      described_class.call(project: other_project, agent_run: run, issue_number: issue.github_number,
        label_preexisting: false)
    }.not_to change(AgentPlanningHold, :count)
  end

  it "preserves a pre-existing label for operator review despite a complete contract" do
    contract = {
      task_kind: "implementation",
      reason: "Awaiting dependencies.",
      release_condition: { kind: "dependencies_resolved" },
      evidence: { scope_revision: "issue@v1" }
    }

    hold = described_class.call(project:, agent_run: run, issue_number: issue.github_number, contract:,
      label_preexisting: true)

    expect(hold).to have_attributes(status: "needs_review", task_kind: nil)
  end

  it "records a structurally invalid contract for operator review" do
    contract = {
      task_kind: "implementation",
      reason: "Awaiting dependencies.",
      release_condition: "dependencies_resolved",
      evidence: { scope_revision: "issue@v1" }
    }

    hold = described_class.call(project:, agent_run: run, issue_number: issue.github_number, contract:,
      label_preexisting: false)

    expect(hold).to have_attributes(status: "needs_review", release_condition: {})
  end

  it "does not let a supplied run-completion condition point at another run" do
    other_run = create(:agent_run, project:)
    contract = {
      task_kind: "implementation",
      reason: "Wait for the originating run.",
      release_condition: { kind: "agent_run_finished", agent_run_id: other_run.id },
      evidence: { scope_revision: "issue@v1" }
    }

    hold = described_class.call(project:, agent_run: run, issue_number: issue.github_number, contract:,
      label_preexisting: false)

    expect(hold).to have_attributes(status: "needs_review", release_condition: { "kind" => "agent_run_finished", "agent_run_id" => other_run.id })
  end

  it "routes an unsupported release condition to operator review" do
    contract = {
      task_kind: "implementation",
      reason: "Awaiting accepted design.",
      release_condition: { kind: "design_revision_accepted", issue_number: issue.github_number },
      evidence: { scope_revision: "rdr-063@draft" }
    }

    hold = described_class.call(project:, agent_run: run, issue_number: issue.github_number, contract:,
      label_preexisting: false)

    expect(hold).to have_attributes(status: "needs_review")
    expect(Notification.where(source: "agent_planning_hold_reconciliation", subject: issue).blocking).to exist
  end
end
