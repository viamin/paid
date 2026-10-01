# frozen_string_literal: true

require "rails_helper"

# @spec RUNNER-FALLBACK-012
RSpec.describe AgentRuns::IssueDispatchFailureHistory do
  subject(:count) { described_class.for_issue(project: project, issue: issue, goal: "create_pr") }

  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  it "counts consecutive no-tier dispatch failures for the same goal" do
    2.times do
      create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
        error_message: "No runner supports tier mid")
    end

    expect(count).to eq(2)
  end

  it "stops at a run that successfully dispatched to a runner" do
    create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
      error_message: "No runner supports tier mid")
    create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
      runners_attempted: [ { "runner" => "claude", "success" => false, "error_type" => "error" } ])
    create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
      error_message: "No runner supports tier high")

    expect(count).to eq(1)
  end

  it "ignores failures for another goal" do
    create(:agent_run, :failed, project: project, issue: issue, goal: "analyze_issue",
      error_message: "No runner supports tier mid")

    expect(count).to eq(0)
  end
end
