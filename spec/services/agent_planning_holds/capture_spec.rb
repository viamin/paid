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
      reason: "Awaiting accepted design.",
      release_condition: { kind: "design_revision_accepted", issue_number: issue.github_number },
      evidence: { scope_revision: "rdr-063@draft", issue_number: issue.github_number }
    }

    2.times do
      described_class.call(project:, agent_run: run, issue_number: issue.github_number, contract:)
    end

    hold = AgentPlanningHold.find_by!(issue:, label: "planning")
    expect(AgentPlanningHold.where(issue:, label: "planning")).to contain_exactly(hold)
    expect(hold).to have_attributes(status: "held", task_kind: "implementation", agent_run: run)
    expect(hold.release_condition).to include("kind" => "design_revision_accepted")
  end

  it "keeps an unknown same-number issue out of another tenant's hold" do
    other_project = create(:project)
    other_run = create(:agent_run, :failed, project: other_project)

    expect {
      described_class.call(project: other_project, agent_run: other_run, issue_number: issue.github_number)
    }.to change(AgentPlanningHold, :count).by(1)

    expect(AgentPlanningHold.last).to have_attributes(project: other_project, issue: nil)
  end

  it "rejects a run from another tenant" do
    other_project = create(:project)

    expect {
      described_class.call(project: other_project, agent_run: run, issue_number: issue.github_number)
    }.not_to change(AgentPlanningHold, :count)
  end
end
